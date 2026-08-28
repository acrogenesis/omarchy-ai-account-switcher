import base64
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("codex_accounts", ROOT / "codex_accounts.py")
codex_accounts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(codex_accounts)


def token(email, account_id, plan="plus"):
    claims = {
        "email": email,
        "https://api.openai.com/auth": {
            "chatgpt_account_id": account_id,
            "chatgpt_plan_type": plan,
        },
    }
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return f"header.{payload}.signature"


def auth(email, account_id, suffix):
    return {
        "auth_mode": "chatgpt",
        "tokens": {
            "id_token": token(email, account_id),
            "access_token": f"access-{suffix}",
            "refresh_token": f"refresh-{suffix}",
            "account_id": account_id,
        },
    }


class CodexAccountsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / "switcher"
        self.codex_home = self.root / "codex"
        self.env = mock.patch.dict(
            os.environ,
            {
                "OMARCHY_CODEX_SWITCHER_DIR": str(self.config),
                "CODEX_HOME": str(self.codex_home),
            },
            clear=False,
        )
        self.env.start()
        self.codex_home.mkdir()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def write_auth(self, value):
        (self.codex_home / "auth.json").write_text(json.dumps(value), encoding="utf-8")

    def read_store(self):
        return json.loads((self.config / "accounts.json").read_text(encoding="utf-8"))

    def test_import_current_is_private_and_sanitized(self):
        self.write_auth(auth("one@example.com", "acct-one", "one"))
        result = codex_accounts.import_current("Personal")
        self.assertEqual(result["message"], "Saved Personal")
        store = self.read_store()
        self.assertEqual(len(store["accounts"]), 1)
        self.assertEqual(store["accounts"][0]["email"], "one@example.com")
        self.assertEqual(stat.S_IMODE((self.config / "accounts.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o700)
        with mock.patch.object(codex_accounts, "running_codex_processes", return_value=[]):
            payload = codex_accounts.status_payload()
        self.assertNotIn("auth_data", payload["accounts"][0])
        self.assertTrue(payload["accounts"][0]["is_current"])

    def test_import_same_identity_updates_tokens_without_duplicate(self):
        self.write_auth(auth("one@example.com", "acct-one", "old"))
        codex_accounts.import_current("Personal")
        self.write_auth(auth("one@example.com", "acct-one", "fresh"))
        codex_accounts.import_current("")
        store = self.read_store()
        self.assertEqual(len(store["accounts"]), 1)
        self.assertEqual(store["accounts"][0]["name"], "Personal")
        self.assertEqual(store["accounts"][0]["auth_data"]["refresh_token"], "refresh-fresh")

    def test_inactive_import_preserves_selected_account(self):
        self.write_auth(auth("one@example.com", "acct-one", "one"))
        codex_accounts.import_current("One")
        first_id = self.read_store()["active_account_id"]
        self.write_auth(auth("two@example.com", "acct-two", "two"))
        codex_accounts.import_current("Two", activate=False)
        store = self.read_store()
        self.assertEqual(len(store["accounts"]), 2)
        self.assertEqual(store["active_account_id"], first_id)

    def test_switch_preserves_rotated_active_tokens(self):
        self.write_auth(auth("one@example.com", "acct-one", "one"))
        codex_accounts.import_current("One")
        first_id = self.read_store()["accounts"][0]["id"]
        self.write_auth(auth("two@example.com", "acct-two", "two"))
        codex_accounts.import_current("Two")
        second_id = self.read_store()["accounts"][1]["id"]

        self.write_auth(auth("two@example.com", "acct-two", "rotated"))
        with mock.patch.object(codex_accounts, "running_codex_processes", return_value=[]):
            result = codex_accounts.switch_account(first_id)
        self.assertEqual(result["message"], "Switched to One")
        store = self.read_store()
        second = next(item for item in store["accounts"] if item["id"] == second_id)
        self.assertEqual(second["auth_data"]["refresh_token"], "refresh-rotated")
        active_auth = json.loads((self.codex_home / "auth.json").read_text(encoding="utf-8"))
        self.assertEqual(active_auth["tokens"]["account_id"], "acct-one")

    def test_switch_blocks_while_codex_is_running(self):
        self.write_auth(auth("one@example.com", "acct-one", "one"))
        codex_accounts.import_current("One")
        self.write_auth(auth("two@example.com", "acct-two", "two"))
        codex_accounts.import_current("Two")
        first_id = self.read_store()["accounts"][0]["id"]

        with mock.patch.object(codex_accounts, "running_codex_processes", return_value=[123, 456]):
            with self.assertRaisesRegex(codex_accounts.SwitcherError, "Close 2 active Codex sessions"):
                codex_accounts.switch_account(first_id)
        current = json.loads((self.codex_home / "auth.json").read_text(encoding="utf-8"))
        self.assertEqual(current["tokens"]["account_id"], "acct-two")

    def test_rename_and_remove(self):
        self.write_auth(auth("one@example.com", "acct-one", "one"))
        codex_accounts.import_current("One")
        account_id = self.read_store()["accounts"][0]["id"]
        codex_accounts.rename_account(account_id, "Work")
        self.assertEqual(self.read_store()["accounts"][0]["name"], "Work")
        codex_accounts.remove_account(account_id)
        self.assertEqual(self.read_store()["accounts"], [])

    def test_api_key_accounts_switch_without_exposing_keys(self):
        self.write_auth({"auth_mode": "api_key", "OPENAI_API_KEY": "sk-test-one"})
        codex_accounts.import_current("API One")
        first_id = self.read_store()["accounts"][0]["id"]
        self.write_auth({"auth_mode": "api_key", "OPENAI_API_KEY": "sk-test-two"})
        codex_accounts.import_current("API Two")

        with mock.patch.object(codex_accounts, "running_codex_processes", return_value=[]):
            payload = codex_accounts.status_payload()
            codex_accounts.switch_account(first_id)
        self.assertNotIn("auth_data", payload["accounts"][0])
        active_auth = json.loads((self.codex_home / "auth.json").read_text(encoding="utf-8"))
        self.assertEqual(active_auth["OPENAI_API_KEY"], "sk-test-one")

    def test_atomic_writer_refuses_destination_symlink(self):
        self.config.mkdir()
        victim = self.root / "victim.json"
        victim.write_text('{"untouched": true}\n', encoding="utf-8")
        (self.config / "accounts.json").symlink_to(victim)
        with self.assertRaisesRegex(codex_accounts.SwitcherError, "Refusing to replace symlink"):
            codex_accounts.atomic_write_json(self.config / "accounts.json", {"changed": True})
        self.assertEqual(json.loads(victim.read_text(encoding="utf-8")), {"untouched": True})


if __name__ == "__main__":
    unittest.main()

import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

import claude_accounts


def credentials(suffix, subscription="team"):
    return {
        "claudeAiOauth": {
            "accessToken": f"access-{suffix}",
            "refreshToken": f"refresh-{suffix}",
            "expiresAt": 2_000_000_000_000,
            "subscriptionType": subscription,
        },
        "mcpOAuth": {"example": {"accessToken": "mcp-token"}},
    }


def state(email, account_uuid, organization="Example"):
    return {
        "theme": "dark",
        "oauthAccount": {
            "emailAddress": email,
            "accountUuid": account_uuid,
            "organizationName": organization,
        },
    }


class ClaudeAccountsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / "switcher"
        self.claude_home = self.root / "claude"
        self.claude_home.mkdir()
        self.env = mock.patch.dict(
            os.environ,
            {
                "HOME": str(self.root),
                "CLAUDE_CONFIG_DIR": str(self.claude_home),
                "OMARCHY_AI_SWITCHER_DIR": str(self.config),
            },
            clear=False,
        )
        self.env.start()
        self.status = mock.patch.object(claude_accounts, "claude_auth_status", return_value={})
        self.status.start()

    def tearDown(self):
        self.status.stop()
        self.env.stop()
        self.temp.cleanup()

    def write_current(self, email, account_uuid, suffix):
        (self.claude_home / ".credentials.json").write_text(
            json.dumps(credentials(suffix)), encoding="utf-8"
        )
        (self.claude_home / ".claude.json").write_text(
            json.dumps(state(email, account_uuid)), encoding="utf-8"
        )

    def read_store(self):
        return json.loads((self.config / "claude-accounts.json").read_text(encoding="utf-8"))

    def test_import_is_private_and_status_is_sanitized(self):
        self.write_current("one@example.com", "uuid-one", "one")
        claude_accounts.import_current("Team")
        store = self.read_store()
        self.assertEqual(store["accounts"][0]["name"], "Team")
        self.assertEqual(store["accounts"][0]["email"], "one@example.com")
        self.assertEqual(stat.S_IMODE((self.config / "claude-accounts.json").stat().st_mode), 0o600)
        with mock.patch.object(claude_accounts, "running_claude_processes", return_value=[]):
            payload = claude_accounts.status_payload()
        self.assertNotIn("credentials", payload["accounts"][0])
        self.assertNotIn("oauth_account", payload["accounts"][0])
        self.assertTrue(payload["accounts"][0]["is_current"])

    def test_inactive_import_preserves_active_account(self):
        self.write_current("one@example.com", "uuid-one", "one")
        claude_accounts.import_current("One")
        first_id = self.read_store()["active_account_id"]
        self.write_current("two@example.com", "uuid-two", "two")
        claude_accounts.import_current("Two", activate=False)
        store = self.read_store()
        self.assertEqual(len(store["accounts"]), 2)
        self.assertEqual(store["active_account_id"], first_id)

    def test_switch_preserves_rotated_tokens_and_unrelated_mcp_credentials(self):
        self.write_current("one@example.com", "uuid-one", "one")
        claude_accounts.import_current("One")
        first_id = self.read_store()["accounts"][0]["id"]
        self.write_current("two@example.com", "uuid-two", "two")
        claude_accounts.import_current("Two")
        second_id = self.read_store()["accounts"][1]["id"]

        rotated = credentials("rotated")
        rotated["mcpOAuth"]["other"] = {"accessToken": "keep-me"}
        (self.claude_home / ".credentials.json").write_text(json.dumps(rotated), encoding="utf-8")
        with mock.patch.object(claude_accounts, "running_claude_processes", return_value=[]):
            claude_accounts.switch_account(first_id)

        store = self.read_store()
        second = next(item for item in store["accounts"] if item["id"] == second_id)
        self.assertEqual(second["credentials"]["refreshToken"], "refresh-rotated")
        active = json.loads((self.claude_home / ".credentials.json").read_text(encoding="utf-8"))
        self.assertEqual(active["claudeAiOauth"]["refreshToken"], "refresh-one")
        self.assertEqual(active["mcpOAuth"]["other"]["accessToken"], "keep-me")
        active_state = json.loads((self.claude_home / ".claude.json").read_text(encoding="utf-8"))
        self.assertEqual(active_state["oauthAccount"]["accountUuid"], "uuid-one")
        self.assertEqual(active_state["theme"], "dark")

    def test_switch_blocks_while_claude_is_running(self):
        self.write_current("one@example.com", "uuid-one", "one")
        claude_accounts.import_current("One")
        first_id = self.read_store()["accounts"][0]["id"]
        self.write_current("two@example.com", "uuid-two", "two")
        claude_accounts.import_current("Two")
        with mock.patch.object(claude_accounts, "running_claude_processes", return_value=[10, 20]):
            with self.assertRaisesRegex(claude_accounts.SwitcherError, "Close 2 active Claude sessions"):
                claude_accounts.switch_account(first_id)
        current = json.loads((self.claude_home / ".credentials.json").read_text(encoding="utf-8"))
        self.assertEqual(current["claudeAiOauth"]["refreshToken"], "refresh-two")

    def test_rename_and_remove(self):
        self.write_current("one@example.com", "uuid-one", "one")
        claude_accounts.import_current("One")
        account_id = self.read_store()["accounts"][0]["id"]
        claude_accounts.rename_account(account_id, "Work")
        self.assertEqual(self.read_store()["accounts"][0]["name"], "Work")
        claude_accounts.remove_account(account_id)
        self.assertEqual(self.read_store()["accounts"], [])


if __name__ == "__main__":
    unittest.main()

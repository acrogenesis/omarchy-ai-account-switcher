#!/usr/bin/python3
"""Local account store and safe auth.json switching for the Omarchy plugin."""

from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


STORE_VERSION = 1


class SwitcherError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def config_dir() -> Path:
    override = os.environ.get("OMARCHY_AI_SWITCHER_DIR") or os.environ.get(
        "OMARCHY_CODEX_SWITCHER_DIR"
    )
    if override:
        return Path(override)
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "omarchy" / "ai-account-switcher"


def store_path() -> Path:
    if os.environ.get("OMARCHY_CODEX_SWITCHER_DIR") and not os.environ.get(
        "OMARCHY_AI_SWITCHER_DIR"
    ):
        return config_dir() / "accounts.json"
    return config_dir() / "codex-accounts.json"


def auth_path() -> Path:
    return Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "auth.json"


def empty_store() -> dict:
    return {"version": STORE_VERSION, "accounts": [], "active_account_id": None}


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SwitcherError(f"File not found: {path}") from None
    except (OSError, json.JSONDecodeError) as error:
        raise SwitcherError(f"Could not read {path.name}: {error}") from None
    if not isinstance(value, dict):
        raise SwitcherError(f"{path.name} must contain a JSON object")
    return value


def load_store() -> dict:
    path = store_path()
    if not path.exists():
        return empty_store()
    store = load_json(path)
    if not isinstance(store.get("accounts"), list):
        raise SwitcherError("accounts.json has an invalid accounts list")
    store.setdefault("version", STORE_VERSION)
    store.setdefault("active_account_id", None)
    return store


def atomic_write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    if path.is_symlink():
        raise SwitcherError(f"Refusing to replace symlink: {path}")
    payload = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except Exception:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise


@contextlib.contextmanager
def account_lock():
    directory = config_dir()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    lock_path = directory / ".lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def jwt_claims(token: str | None) -> dict:
    if not token or token.count(".") != 2:
        return {}
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        value = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
        return value if isinstance(value, dict) else {}
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return {}


def chatgpt_metadata(tokens: dict) -> dict:
    claims = jwt_claims(tokens.get("id_token"))
    auth = claims.get("https://api.openai.com/auth")
    if not isinstance(auth, dict):
        auth = {}
    return {
        "email": claims.get("email") if isinstance(claims.get("email"), str) else None,
        "plan_type": auth.get("chatgpt_plan_type")
        if isinstance(auth.get("chatgpt_plan_type"), str)
        else None,
        "account_id": auth.get("chatgpt_account_id")
        if isinstance(auth.get("chatgpt_account_id"), str)
        else tokens.get("account_id"),
        "subscription_expires_at": auth.get("chatgpt_subscription_active_until")
        if isinstance(auth.get("chatgpt_subscription_active_until"), str)
        else None,
    }


def account_from_auth(auth: dict, name: str = "") -> dict:
    api_key = auth.get("OPENAI_API_KEY")
    tokens = auth.get("tokens")
    now = utc_now()
    if isinstance(api_key, str) and api_key:
        display_name = name.strip() or "API key account"
        return {
            "id": str(uuid.uuid4()),
            "name": display_name,
            "email": None,
            "plan_type": None,
            "subscription_expires_at": None,
            "auth_mode": "api_key",
            "auth_data": {"type": "api_key", "key": api_key},
            "created_at": now,
            "last_used_at": None,
        }
    if isinstance(tokens, dict) and all(
        isinstance(tokens.get(key), str) and tokens.get(key)
        for key in ("id_token", "access_token", "refresh_token")
    ):
        metadata = chatgpt_metadata(tokens)
        account_id = metadata["account_id"]
        suffix = str(account_id or "")[-8:]
        display_name = (
            name.strip()
            or metadata["email"]
            or (f"ChatGPT account ({suffix})" if suffix else "ChatGPT account")
        )
        return {
            "id": str(uuid.uuid4()),
            "name": display_name,
            "email": metadata["email"],
            "plan_type": metadata["plan_type"],
            "subscription_expires_at": metadata["subscription_expires_at"],
            "auth_mode": "chat_gpt",
            "auth_data": {
                "type": "chat_gpt",
                "id_token": tokens["id_token"],
                "access_token": tokens["access_token"],
                "refresh_token": tokens["refresh_token"],
                "account_id": account_id,
            },
            "created_at": now,
            "last_used_at": None,
        }
    raise SwitcherError("Codex auth.json contains no usable login")


def account_identity(account: dict) -> str | None:
    auth_data = account.get("auth_data")
    if not isinstance(auth_data, dict):
        return None
    if account.get("auth_mode") == "api_key" or auth_data.get("type") == "api_key":
        key = auth_data.get("key")
        return f"api:{hashlib.sha256(key.encode()).hexdigest()}" if isinstance(key, str) else None
    account_id = auth_data.get("account_id")
    if isinstance(account_id, str) and account_id:
        return f"chat:{account_id}"
    metadata = chatgpt_metadata(auth_data)
    if metadata["account_id"]:
        return f"chat:{metadata['account_id']}"
    if metadata["email"]:
        return f"email:{metadata['email'].lower()}"
    return None


def current_account() -> dict | None:
    path = auth_path()
    if not path.exists():
        return None
    return account_from_auth(load_json(path))


def find_matching_account(store: dict, candidate: dict | None) -> dict | None:
    identity = account_identity(candidate or {})
    if not identity:
        return None
    return next(
        (account for account in store["accounts"] if account_identity(account) == identity),
        None,
    )


def running_codex_processes() -> list[int]:
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,tty=,comm=,args="],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise SwitcherError(f"Could not inspect running Codex sessions: {error}") from None
    pids: list[int] = []
    for raw_line in result.stdout.splitlines():
        parts = raw_line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        pid_text, tty, command_name, arguments = parts
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        if pid == os.getpid():
            continue
        first_argument = arguments.split(None, 1)[0] if arguments else ""
        is_codex = Path(command_name).name == "codex" or Path(first_argument).name == "codex"
        lowered = arguments.lower()
        if not is_codex or "codex app-server" in lowered or "codex-code-mode-host" in lowered:
            continue
        if tty not in ("?", "??", "-"):
            pids.append(pid)
    return sorted(set(pids))


def sanitized_account(account: dict, active_id: str | None, current_id: str | None) -> dict:
    return {
        "id": str(account.get("id", "")),
        "name": str(account.get("name", "Account")),
        "email": account.get("email"),
        "plan_type": account.get("plan_type"),
        "auth_mode": account.get("auth_mode"),
        "is_active": account.get("id") == active_id,
        "is_current": account.get("id") == current_id,
        "last_used_at": account.get("last_used_at"),
    }


def status_payload() -> dict:
    store = load_store()
    current = current_account()
    matched = find_matching_account(store, current)
    current_id = matched.get("id") if matched else None
    active_id = current_id or store.get("active_account_id")
    pids = running_codex_processes()
    suggested_name = current.get("name") if current else ""
    return {
        "ok": True,
        "provider": "codex",
        "accounts": [sanitized_account(account, active_id, current_id) for account in store["accounts"]],
        "active_account_id": active_id,
        "current_saved": matched is not None,
        "has_current_login": current is not None,
        "suggested_name": suggested_name,
        "can_switch": not pids,
        "running_count": len(pids),
    }


def import_current(name: str, activate: bool = True) -> dict:
    with account_lock():
        store = load_store()
        previous_active_id = store.get("active_account_id")
        candidate = current_account()
        if candidate is None:
            raise SwitcherError("No Codex login is available to save")
        existing = find_matching_account(store, candidate)
        if existing:
            preserved_id = existing["id"]
            preserved_created = existing.get("created_at") or candidate["created_at"]
            preserved_last_used = existing.get("last_used_at")
            if name.strip():
                candidate["name"] = name.strip()
            else:
                candidate["name"] = existing.get("name") or candidate["name"]
            candidate["id"] = preserved_id
            candidate["created_at"] = preserved_created
            candidate["last_used_at"] = preserved_last_used
            existing.clear()
            existing.update(candidate)
            saved = existing
        else:
            if name.strip():
                candidate["name"] = name.strip()
            store["accounts"].append(candidate)
            saved = candidate
        if activate:
            store["active_account_id"] = saved["id"]
        else:
            store["active_account_id"] = previous_active_id
        atomic_write_json(store_path(), store)
        return {"ok": True, "message": f"Saved {saved['name']}"}


def sync_current_into_store(store: dict) -> None:
    current = current_account()
    matched = find_matching_account(store, current)
    if not current or not matched:
        return
    preserved = {
        "id": matched["id"],
        "name": matched.get("name") or current["name"],
        "created_at": matched.get("created_at") or current["created_at"],
        "last_used_at": matched.get("last_used_at"),
    }
    matched.clear()
    matched.update(current)
    matched.update(preserved)
    store["active_account_id"] = matched["id"]


def auth_from_account(account: dict) -> dict:
    data = account.get("auth_data")
    if not isinstance(data, dict):
        raise SwitcherError("The selected account has invalid credentials")
    if account.get("auth_mode") == "api_key" or data.get("type") == "api_key":
        key = data.get("key")
        if not isinstance(key, str) or not key:
            raise SwitcherError("The selected API key account is incomplete")
        return {"auth_mode": "api_key", "OPENAI_API_KEY": key}
    required = ("id_token", "access_token", "refresh_token")
    if not all(isinstance(data.get(key), str) and data.get(key) for key in required):
        raise SwitcherError("The selected ChatGPT account is incomplete")
    tokens = {key: data[key] for key in required}
    if data.get("account_id"):
        tokens["account_id"] = data["account_id"]
    return {
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": None,
        "tokens": tokens,
        "last_refresh": utc_now(),
    }


def switch_account(account_id: str) -> dict:
    with account_lock():
        store = load_store()
        target = next((item for item in store["accounts"] if item.get("id") == account_id), None)
        if not target:
            raise SwitcherError("Account not found")
        sync_current_into_store(store)
        current = current_account()
        if account_identity(target) != account_identity(current or {}):
            pids = running_codex_processes()
            if pids:
                count = len(pids)
                raise SwitcherError(
                    f"Close {count} active Codex session{'s' if count != 1 else ''} before switching"
                )
            atomic_write_json(auth_path(), auth_from_account(target))
        target["last_used_at"] = utc_now()
        store["active_account_id"] = target["id"]
        atomic_write_json(store_path(), store)
        return {"ok": True, "message": f"Switched to {target['name']}"}


def rename_account(account_id: str, name: str) -> dict:
    cleaned = name.strip()
    if not cleaned:
        raise SwitcherError("Account name cannot be empty")
    with account_lock():
        store = load_store()
        account = next((item for item in store["accounts"] if item.get("id") == account_id), None)
        if not account:
            raise SwitcherError("Account not found")
        account["name"] = cleaned
        atomic_write_json(store_path(), store)
    return {"ok": True, "message": f"Renamed account to {cleaned}"}


def remove_account(account_id: str) -> dict:
    with account_lock():
        store = load_store()
        before = len(store["accounts"])
        store["accounts"] = [item for item in store["accounts"] if item.get("id") != account_id]
        if len(store["accounts"]) == before:
            raise SwitcherError("Account not found")
        if store.get("active_account_id") == account_id:
            store["active_account_id"] = None
        atomic_write_json(store_path(), store)
    return {"ok": True, "message": "Removed saved account"}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status")
    subparsers.add_parser("assert-idle")
    import_parser = subparsers.add_parser("import-current")
    import_parser.add_argument("name", nargs="?", default="")
    import_parser.add_argument("--inactive", action="store_true")
    switch_parser = subparsers.add_parser("switch")
    switch_parser.add_argument("account_id")
    rename_parser = subparsers.add_parser("rename")
    rename_parser.add_argument("account_id")
    rename_parser.add_argument("name")
    remove_parser = subparsers.add_parser("remove")
    remove_parser.add_argument("account_id")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "status":
            result = status_payload()
        elif args.command == "assert-idle":
            pids = running_codex_processes()
            if pids:
                raise SwitcherError(
                    f"Close {len(pids)} active Codex session{'s' if len(pids) != 1 else ''} first"
                )
            result = {"ok": True, "message": "No active Codex sessions"}
        elif args.command == "import-current":
            result = import_current(args.name, activate=not args.inactive)
        elif args.command == "switch":
            result = switch_account(args.account_id)
        elif args.command == "rename":
            result = rename_account(args.account_id, args.name)
        else:
            result = remove_account(args.account_id)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except SwitcherError as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())

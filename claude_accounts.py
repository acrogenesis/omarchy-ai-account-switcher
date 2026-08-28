#!/usr/bin/python3
"""Local Claude Code account storage and safe provider switching."""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import uuid

from codex_accounts import (
    SwitcherError,
    account_lock,
    atomic_write_json,
    config_dir,
    utc_now,
)


STORE_VERSION = 1


def store_path() -> Path:
    return config_dir() / "claude-accounts.json"


def claude_config_dir() -> Path:
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(override) if override else Path.home() / ".claude"


def credentials_path() -> Path:
    return claude_config_dir() / ".credentials.json"


def state_path() -> Path:
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(override) / ".claude.json" if override else Path.home() / ".claude.json"


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
        raise SwitcherError("claude-accounts.json has an invalid accounts list")
    store.setdefault("version", STORE_VERSION)
    store.setdefault("active_account_id", None)
    return store


def load_optional_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return load_json(path)


def write_json_without_parent_chmod(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise SwitcherError(f"Refusing to replace symlink: {path}")
    current_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    payload = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, current_mode)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, current_mode)
    except Exception:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise


def claude_auth_status() -> dict:
    command = shutil.which("claude")
    if not command:
        return {}
    try:
        result = subprocess.run(
            [command, "auth", "status", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if result.returncode != 0:
        return {}
    try:
        value = json.loads(result.stdout)
        return value if isinstance(value, dict) else {}
    except json.JSONDecodeError:
        return {}


def current_account(name: str = "", query_status: bool = False) -> dict | None:
    path = credentials_path()
    if not path.exists():
        return None
    credentials_document = load_json(path)
    oauth_credentials = credentials_document.get("claudeAiOauth")
    if not isinstance(oauth_credentials, dict) or not oauth_credentials.get("accessToken"):
        return None

    state = load_optional_json(state_path())
    oauth_account = state.get("oauthAccount")
    if not isinstance(oauth_account, dict):
        oauth_account = {}
    status = {}
    if query_status or not oauth_account.get("emailAddress"):
        status = claude_auth_status()

    email = oauth_account.get("emailAddress") or status.get("email")
    org_name = oauth_account.get("organizationName") or status.get("orgName")
    subscription_type = (
        status.get("subscriptionType")
        or oauth_credentials.get("subscriptionType")
        or oauth_account.get("seatTier")
    )
    account_uuid = oauth_account.get("accountUuid")
    suffix = str(account_uuid or "")[-8:]
    display_name = name.strip() or email or (f"Claude account ({suffix})" if suffix else "Claude account")

    return {
        "id": str(uuid.uuid4()),
        "name": display_name,
        "email": email if isinstance(email, str) else None,
        "org_name": org_name if isinstance(org_name, str) else None,
        "subscription_type": subscription_type if isinstance(subscription_type, str) else None,
        "credentials": oauth_credentials,
        "oauth_account": oauth_account or None,
        "created_at": utc_now(),
        "last_used_at": None,
    }


def account_identity(account: dict | None) -> str | None:
    if not isinstance(account, dict):
        return None
    oauth_account = account.get("oauth_account")
    if isinstance(oauth_account, dict) and oauth_account.get("accountUuid"):
        return f"uuid:{oauth_account['accountUuid']}"
    email = account.get("email")
    if isinstance(email, str) and email:
        return f"email:{email.lower()}"
    credentials = account.get("credentials")
    if isinstance(credentials, dict):
        refresh_token = credentials.get("refreshToken")
        if isinstance(refresh_token, str) and refresh_token:
            return f"token:{hashlib.sha256(refresh_token.encode()).hexdigest()}"
    return None


def find_matching_account(store: dict, candidate: dict | None) -> dict | None:
    identity = account_identity(candidate)
    if not identity:
        return None
    return next(
        (account for account in store["accounts"] if account_identity(account) == identity),
        None,
    )


def running_claude_processes() -> list[int]:
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,tty=,comm=,args="],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise SwitcherError(f"Could not inspect running Claude sessions: {error}") from None
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
        is_claude = Path(command_name).name == "claude" or Path(first_argument).name == "claude"
        if is_claude and tty not in ("?", "??", "-"):
            pids.append(pid)
    return sorted(set(pids))


def sanitized_account(account: dict, active_id: str | None, current_id: str | None) -> dict:
    return {
        "id": str(account.get("id", "")),
        "name": str(account.get("name", "Account")),
        "email": account.get("email"),
        "org_name": account.get("org_name"),
        "subscription_type": account.get("subscription_type"),
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
    pids = running_claude_processes()
    return {
        "ok": True,
        "provider": "claude",
        "accounts": [sanitized_account(account, active_id, current_id) for account in store["accounts"]],
        "active_account_id": active_id,
        "current_saved": matched is not None,
        "has_current_login": current is not None,
        "suggested_name": current.get("name") if current else "",
        "can_switch": not pids,
        "running_count": len(pids),
    }


def import_current(name: str, activate: bool = True) -> dict:
    with account_lock():
        store = load_store()
        previous_active_id = store.get("active_account_id")
        candidate = current_account(name=name, query_status=True)
        if candidate is None:
            raise SwitcherError("No Claude login is available to save")
        existing = find_matching_account(store, candidate)
        if existing:
            preserved_id = existing["id"]
            preserved_created = existing.get("created_at") or candidate["created_at"]
            preserved_last_used = existing.get("last_used_at")
            candidate["name"] = name.strip() or existing.get("name") or candidate["name"]
            candidate["id"] = preserved_id
            candidate["created_at"] = preserved_created
            candidate["last_used_at"] = preserved_last_used
            existing.clear()
            existing.update(candidate)
            saved = existing
        else:
            store["accounts"].append(candidate)
            saved = candidate
        store["active_account_id"] = saved["id"] if activate else previous_active_id
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


def write_active_account(account: dict) -> None:
    credentials = account.get("credentials")
    if not isinstance(credentials, dict) or not credentials.get("accessToken"):
        raise SwitcherError("The selected Claude account has invalid credentials")

    credentials_document = load_optional_json(credentials_path())
    credentials_document["claudeAiOauth"] = credentials
    # Claude keeps this file inside its own config directory. Preserve the
    # directory's existing permissions and unrelated provider credentials.
    write_json_without_parent_chmod(credentials_path(), credentials_document)

    oauth_account = account.get("oauth_account")
    if isinstance(oauth_account, dict) and oauth_account:
        state = load_optional_json(state_path())
        state["oauthAccount"] = oauth_account
        write_json_without_parent_chmod(state_path(), state)


def switch_account(account_id: str) -> dict:
    with account_lock():
        store = load_store()
        target = next((item for item in store["accounts"] if item.get("id") == account_id), None)
        if not target:
            raise SwitcherError("Account not found")
        sync_current_into_store(store)
        current = current_account()
        if account_identity(target) != account_identity(current):
            pids = running_claude_processes()
            if pids:
                count = len(pids)
                raise SwitcherError(
                    f"Close {count} active Claude session{'s' if count != 1 else ''} before switching"
                )
            write_active_account(target)
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

#!/usr/bin/python3
"""Provider-aware command interface for Codex and Claude account switching."""

from __future__ import annotations

import argparse
import json
import sys

import claude_accounts
import codex_accounts
from codex_accounts import SwitcherError


PROVIDERS = {
    "codex": codex_accounts,
    "claude": claude_accounts,
}


def combined_status() -> dict:
    statuses = {}
    for provider, module in PROVIDERS.items():
        try:
            statuses[provider] = module.status_payload()
        except SwitcherError as error:
            statuses[provider] = {
                "ok": False,
                "provider": provider,
                "accounts": [],
                "error": str(error),
            }
    return {"ok": True, "providers": statuses}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status")

    import_parser = subparsers.add_parser("import-current")
    import_parser.add_argument("provider", choices=PROVIDERS)
    import_parser.add_argument("name", nargs="?", default="")
    import_parser.add_argument("--inactive", action="store_true")

    switch_parser = subparsers.add_parser("switch")
    switch_parser.add_argument("provider", choices=PROVIDERS)
    switch_parser.add_argument("account_id")

    rename_parser = subparsers.add_parser("rename")
    rename_parser.add_argument("provider", choices=PROVIDERS)
    rename_parser.add_argument("account_id")
    rename_parser.add_argument("name")

    remove_parser = subparsers.add_parser("remove")
    remove_parser.add_argument("provider", choices=PROVIDERS)
    remove_parser.add_argument("account_id")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "status":
            result = combined_status()
        else:
            module = PROVIDERS[args.provider]
            if args.command == "import-current":
                result = module.import_current(args.name, activate=not args.inactive)
            elif args.command == "switch":
                result = module.switch_account(args.account_id)
            elif args.command == "rename":
                result = module.rename_account(args.account_id, args.name)
            else:
                result = module.remove_account(args.account_id)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except SwitcherError as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())

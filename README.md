# AI Account Switcher for Omarchy

A native Omarchy Quattro bar plugin for saving and switching personal Codex CLI
and Claude Code accounts.

## Features

- Separate Codex and Claude account lists in one compact menubar panel.
- Uses the official `codex login` and `claude auth login` flows.
- Adds accounts in an isolated temporary config, so active sessions and the
  current login are not disturbed.
- Preserves credentials refreshed by the currently selected account before a
  switch.
- Preserves Claude's unrelated `mcpOAuth` data when changing Claude accounts.
- Blocks only an actual provider account change while that provider has active
  interactive sessions. Saving or adding an account remains available.
- Keeps credential stores local with `0700` directory and `0600` file modes.

## Requirements

- Omarchy Quattro with plugin support
- `bash`, `jq`, `flock`, `base64`, and `sha256sum` (included in Omarchy's base system)
- `codex` for Codex accounts
- `claude` for Claude accounts

## Install

```bash
omarchy plugin add https://github.com/acrogenesis/omarchy-ai-account-switcher.git --enable
```

The plugin appears in the right side of the bar. Open it, select Codex or
Claude, and save the login currently active on the machine. **Add another
account** automatically refreshes that saved copy and immediately launches the
provider's official login in a terminal using an isolated `CODEX_HOME` or
`CLAUDE_CONFIG_DIR`; there is no pre-login confirmation prompt.

Adding an account does not require closing existing sessions. Close that
provider's interactive sessions only when selecting a different saved account;
new sessions then inherit the selected login.

## Local data

Saved credentials are kept outside the plugin checkout:

```text
~/.config/omarchy/ai-account-switcher/
├── codex-accounts.json
└── claude-accounts.json
```

For Claude, only `claudeAiOauth` is stored per account. Switching merges it into
`~/.claude/.credentials.json` instead of replacing the document, retaining MCP
OAuth credentials and other unrelated state. Claude account display metadata is
restored in `~/.claude.json`.

Removing the plugin does not delete saved credentials. Delete the directory
above separately if you also want to remove the saved account copies.

## Remove

```bash
omarchy plugin remove acrogenesis.ai-account-switcher
```

The command removes the plugin but deliberately leaves the private account
store intact. To remove those additional local copies too:

```bash
rm -r ~/.config/omarchy/ai-account-switcher
```

This does not log out Codex or Claude and does not delete their live provider
configuration.

## Security model

This plugin necessarily reads and writes local Codex and Claude authentication
files when the user explicitly saves or switches an account. Saved credential
copies never leave the machine, are excluded from command and QML output, and
are written under a private `0700` directory with `0600` files. Account changes
are locked and atomic, and destination symlinks are rejected.

Review the source before installation. Omarchy plugins execute as unsandboxed
user code; marketplace validation is compatibility checking, not a security
audit.

## IPC

```bash
omarchy-shell acrogenesis.ai-account-switcher status
omarchy-shell acrogenesis.ai-account-switcher refresh
omarchy-shell acrogenesis.ai-account-switcher toggle
omarchy-shell acrogenesis.ai-account-switcher selectProvider claude
omarchy-shell acrogenesis.ai-account-switcher saveCurrent codex "Personal"
omarchy-shell acrogenesis.ai-account-switcher switchAccount claude ACCOUNT_ID
```

Provider values are `codex` and `claude`.

## Development

```bash
bash tests/test_accounts.sh
bash tests/test_add_codex_account.sh
bash tests/test_add_claude_account.sh
bash -n ai_accounts.sh AddCodexAccount.sh AddClaudeAccount.sh tests/*.sh
omarchy plugin validate .
```

## Design references

The Codex flow was inspired by
[Lampese/codex-switcher](https://github.com/Lampese/codex-switcher), while the
provider-separated model and Claude credential behavior were informed by
[Symbioose/claude-account-switcher](https://github.com/Symbioose/claude-account-switcher).
The implementation here is native to Omarchy and does not bundle either tool.

## License

MIT

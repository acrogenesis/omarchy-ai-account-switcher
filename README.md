# AI Account Switcher for Omarchy

A native Omarchy Quattro bar plugin for saving and switching personal Codex CLI
and Claude Code accounts.

## Features

- Separate Codex and Claude account lists in one compact menubar panel.
- Uses the official `codex login` and `claude auth login` flows.
- Gives every account a stable isolated `CODEX_HOME` or `CLAUDE_CONFIG_DIR`.
- Opens the selected account in a new terminal without rewriting the shared
  Codex or Claude login.
- Lets existing sessions keep the account they started with while other
  accounts run alongside them.
- Retains credentials refreshed inside each account home and seeds Claude
  homes with existing unrelated `mcpOAuth` data.
- Keeps credential stores local with `0700` directory and `0600` file modes.

## Requirements

- Omarchy Quattro with plugin support
- `bash`, `jq`, `flock`, and `base64` (included in Omarchy's base system)
- `codex` for Codex accounts
- `claude` for Claude accounts

## Install

```bash
omarchy plugin add https://github.com/acrogenesis/omarchy-ai-account-switcher.git --enable
```

The plugin appears in the right side of the bar. Open it, select Codex or
Claude, and save the login currently active on the machine. Select any saved
account and press **Open Codex/Claude as ...** to start a terminal using that
account's isolated provider home. Selecting another account later does not
change any already-open session.

**Add another account** immediately launches the provider's official login in
an isolated temporary home; there is no pre-login confirmation prompt. After
login, the plugin promotes it to a stable private account home. No operation
requires closing active Codex or Claude sessions.

Running `codex` or `claude` directly in an unrelated terminal continues to use
the provider's normal shared login. Use the panel's **Open** action when you
want a saved switcher account.

## Local data

Saved credentials are kept outside the plugin checkout:

```text
~/.config/omarchy/ai-account-switcher/
├── codex-accounts.json
├── claude-accounts.json
└── homes/
    ├── codex/ACCOUNT_ID/
    └── claude/ACCOUNT_ID/
```

The homes contain each account's credentials, refreshed tokens, and session
state. Common user configuration such as Codex skills/rules and Claude
settings/plugins is linked from the normal provider home when an account home
is first created. Claude homes begin with the shared credential document's
unrelated MCP OAuth entries, then refresh independently.

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

This plugin reads the normal Codex or Claude authentication file only when the
user explicitly saves that login. Selecting or opening a saved account does not
rewrite those shared files. Saved credentials never leave the machine, are
excluded from command and QML output, and are written under private `0700`
directories with `0600` files. Account changes are locked and atomic, and
destination symlinks are rejected.

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
omarchy-shell acrogenesis.ai-account-switcher launchSelected claude
```

Provider values are `codex` and `claude`.

## Development

```bash
bash tests/test_accounts.sh
bash tests/test_add_codex_account.sh
bash tests/test_add_claude_account.sh
bash tests/test_launch_account.sh
bash -n ai_accounts.sh AddCodexAccount.sh AddClaudeAccount.sh LaunchAccount.sh tests/*.sh
omarchy plugin validate .
```

## Design references

The per-session isolation model uses the providers' documented configuration
roots: OpenAI's [`CODEX_HOME`](https://learn.chatgpt.com/docs/config-file/environment-variables)
and Anthropic's [`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/env-vars),
which Anthropic explicitly supports for running multiple accounts side by side.

The Codex flow was inspired by
[Lampese/codex-switcher](https://github.com/Lampese/codex-switcher), while the
provider-separated model and Claude credential behavior were informed by
[Symbioose/claude-account-switcher](https://github.com/Symbioose/claude-account-switcher).
The implementation here is native to Omarchy and does not bundle either tool.

## License

MIT

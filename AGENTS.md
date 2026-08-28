# Repository guidance

This repository is the Omarchy Quattro plugin
`acrogenesis.ai-account-switcher`.

## Invariants

- Never print provider tokens or persist them outside the private account
  stores.
- Keep the Codex and Claude stores separate; the same email can be saved for
  both providers.
- Adding an account must use an isolated `CODEX_HOME` or
  `CLAUDE_CONFIG_DIR` and must not log out or alter the live login.
- Before switching away, sync the live provider credentials back into the
  currently saved account so refreshed tokens are retained.
- Block only a real account change while interactive sessions for that provider
  are running. Selecting the already-current account must remain safe.
- Claude switching replaces only `claudeAiOauth`; preserve `mcpOAuth` and all
  other keys in `~/.claude/.credentials.json`.
- Credential directories and files must remain `0700` and `0600` respectively,
  and writers must refuse destination symlinks.

## Validation

Run `tests/test_accounts.sh`, both add-account integration tests, Bash syntax
checks, `omarchy plugin validate .`, and QML linting for changed files. For bar
or panel changes, also reload the shell and verify the live IPC and rendered
panel.

Do not commit, push, publish, release, or create project-management work unless
the user explicitly requests it.

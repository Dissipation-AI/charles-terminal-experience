# Idea: agent accounts in one click (CTX.app, future)

Noted 2026-10-24. Not scheduled.

Most people won't create macOS accounts by hand for their agents. Today it took: creating vibe-daemon and sys-ops-monkey in System Settings, `chmod 700 ~`, ACLs on ~ and ~/Workspaces, `sudo scripts/install-helper.sh`, editing `account =` in config.toml, and `claude setup-token` as each account. CTX.app should do all of it from one place.

## What the app would do

- In an agent's settings: "Run as its own Mac user". One admin password prompt (Authorization Services, the same right the helper already uses) covers the whole setup.
- Create a hidden account (`sysadminctl -addUser` plus `IsHidden`), named after the agent, with a random password the user never needs.
- Install or update ctx-helper and write its rules for that agent.
- Close the user's home (700) after showing what changes, and add ACLs for exactly the agent's `folders` and `write` paths (with inheritance), plus search on the folders above them.
- Log the agent's tools in: run `claude setup-token` (and codex/agy equivalents) inside the new account's tab so the token lands in that account's keychain.
- Put `account = "<name>"` in config.toml.
- An undo that removes the ACLs, the rules and the account (after asking about its home folder).

## Things learned that the flow has to handle

- An agent account can only reach `ctx` and agent programs outside the user's home, or inside folders it was given. CTX.app's bundled `ctx` works; a dev build under ~ needs the ACLs.
- `chmod -R +a` fails on broken symlinks (22 in ~/Workspaces, all old wandb runs and .venv links); that is harmless.
- The helper refuses rules where an agent account is the owner.
- Agent accounts aren't admins. Sudo for the sysadmin account is a separate, explicit grant.

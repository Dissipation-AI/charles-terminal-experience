# Agents: what's done and what's left (2026-10-24)

## Done

- ACLs: vibe-daemon can search your home, and vibe-daemon and you both have full, inherited access to ~/Workspaces. The 22 errors were broken symlinks (old wandb runs, two .venv links), harmless.
- Merged: Dissipation-AI/ctx#7 (CI passed) and Dissipation-AI/ctx-app#4. The monorepo points at both.
- Built and ready to install: CTX.app with ctx protocol 5 and bro, plus the ctx and bro command-line builds. The config for agents is checked with `ctx list agents`.

## 0. Run the reinstall (Terminal.app, not CTX)

Stopping the ctx server ends the shells in every ctx tab, so the script has to run outside CTX. Open Terminal.app and paste (it's on your clipboard):

```
/private/tmp/claude-501/-Users-c-Workspaces-charles-terminal-experience/c1beab40-ddc2-4978-bde2-dbce057891ad/scratchpad/reinstall.sh
```

It takes about a minute: swaps in the new ctx and bro builds (~/.local/bin points into the checkouts), turns agents on in ~/.config/ctx/config.toml (backup: config.toml.before-agents), reinstalls CTX.app in /Applications and restarts the server, then reinstalls ctx's Claude plugin, which removes the stale `ctx mcp` processes. Privacy permissions are kept, not reset. Log: /private/tmp/claude-501/-Users-c-Workspaces-charles-terminal-experience/c1beab40-ddc2-4978-bde2-dbce057891ad/scratchpad/reinstall.log

Every agent is sandboxed and runs as you for now; the `account =` lines stay commented out until the logins exist (steps 3 and 4). `ctx list agents` shows each one.

## 1. Pick your sessions back up

Restarting the server ended the shells in every tab. `ctx list tabs` shows them closed; bring each back with `ctx reopen tab <n>` (they were 330, 336 and 340), then `claude --resume` in each. The ctx build session is `c1beab40-ddc2-4978-bde2-dbce057891ad`, in ~/Workspaces/charles-terminal-experience. To have it check the reinstall: `claude --resume c1beab40-ddc2-4978-bde2-dbce057891ad`, then "verify the reinstall".

Claude now starts as an agent: in ~/Workspaces it's dev (sandboxed: no ~/Desktop, ~/Documents, ~/Downloads, ~/Context, ~/Agents, ~/Library, ~/.ssh keys, other services' tokens); in ~/Agents/email-agent it's email-agent (writes only its folder). It prints `ctx: claude runs as the agent "dev", in its sandbox.` when it starts.

## 2. Try it and look for disconnects

- `ctx list agents` and `ctx list tabs` (tabs now show which agent owns them).
- In dev's Claude: ask it to read a file in ~/Context (should be refused), to build and test something in ~/Workspaces (should work), and to run `ps`.
- In the email agent: anything that writes outside ~/Agents/email-agent will fail. That's the most likely real disconnect (Proton Bridge config, a Python env elsewhere); add those paths to its `write` or `read`.
- `ctx list activity` names the agent behind each command.

## 3. dev as vibe-daemon

1. Get a shell as vibe-daemon: `su - vibe-daemon` (its password), then `claude setup-token` and follow the login. `claude` and `ctx` are reachable from its account through ~/.local/bin now that it can search your home.
2. In ~/.config/ctx/config.toml, under `[agents.dev]`, uncomment `account = "vibe-daemon"`.
3. Claude started in ~/Workspaces then runs in a tab of dev's, as vibe-daemon. Its files there belong to vibe-daemon; the ACLs keep them yours to edit too.

## 4. sysadmin as sys-ops-monkey

Not done yet: sys-ops-monkey can't reach ~/Agents/sys-admin. Run:

```
chmod +a "sys-ops-monkey allow search" ~ ~/Agents
chmod -R +a "sys-ops-monkey allow list,search,readattr,readextattr,read,write,append,add_file,add_subdirectory,delete,delete_child,writeattr,writeextattr,file_inherit,directory_inherit" ~/Agents/sys-admin
chmod -R +a "c allow list,search,readattr,readextattr,read,write,append,add_file,add_subdirectory,delete,delete_child,writeattr,writeextattr,file_inherit,directory_inherit" ~/Agents/sys-admin
```

Then `su - sys-ops-monkey`, `claude setup-token`, and uncomment `account = "sys-ops-monkey"` under `[agents.sysadmin]`. For sudo, make it an admin: `sudo dseditgroup -o edit -a sys-ops-monkey -t user admin` (undo with `-d` instead of `-a`). Being its own account, it can't read the rest of your home even unsandboxed; "sees everything" now means every tab, not every file.

## 5. Desktop prompt test

With dev sandboxed, ask its Claude to `ls ~/Desktop`. It should get "Operation not permitted" with no macOS prompt. If a prompt appears, deny it and say so.

## Later: accounts in one click

Written up in docs/idea-agent-accounts-in-the-app.md: CTX.app would create the hidden account, install the helper, set the ACLs, log the agent's tools in and edit config.toml behind one admin prompt, with an undo.

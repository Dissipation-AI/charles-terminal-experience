# Permissions review: per-agent scoping (2026-10-23)

Status: review only, nothing changed. Items marked **tested** were run on this Mac (macOS 27.0.1) today; **not verified** means researched or reasoned, not tried.

## How it works now

- **Tab shells are disclaimed and fail closed for Full Disk Access.** Each tab's shell is started by `ctx-launch` with `responsibility_spawnattrs_setdisclaim`, so macOS doesn't hold the terminal responsible. Mail, Messages, Safari and the TCC database give `Operation not permitted` (phase0.md).
- **But the identity is CTX.app's (tested).** The running server and every `ctx-launch` are `/Applications/CTX.app/Contents/Resources/bin/…`. A binary inside an app bundle is attributed to that bundle, so `ls ~/Desktop` in any tab prompts for "CTX". If you click Allow, every tab gets Desktop, Documents or Downloads, including every Claude session. Until this is fixed, answer Don't Allow. (The phase-0 finding, "readable without a prompt", was with `ctx-launch` outside the bundle; the CTX.app install moved it inside.)
- **Everything runs as you.** Every tab is uid 501. A tab can read `~/.ssh/id_ed25519_github` (tested), push with your keys, edit your launch agents, and kill your processes. TCC protects some locations and nothing else.
- **Scoped launchers** (`ctx make launcher`) hold a grant on a narrow signed binary and stay the responsible process for what they start. That's how `sysadmin` gets Full Disk Access for one Claude. It works, but it only *adds* access; nothing *removes* access from ordinary agent tabs.
- **Who ran what** is inferred from process ancestry (a known agent program such as `claude` or `agy` above the client, or `CTX_AGENT_NAME`), plus the launcher name. It names the program, not the agent: the software-dev Claude and the email Claude are both "claude". A process running as you can lie about its ancestry by being started some other way (launchd, `open`), so this identity is good for an audit log, not for a security boundary.
- **The ctx socket lets any agent drive any tab (tested).** A process under a seatbelt profile could still `ctx list tabs`, and so `ctx run in "<your tab>" …` would run outside its sandbox. The Bash hook makes this the normal path: Claude's commands run in a tab the *server* spawns, so whatever sandbox Claude itself is in doesn't apply to them.

## What you're after (as read from your messages)

1. **The agent is the principal, not the program.** "software dev", "sysadmin" and "email" are different agents even though all three are Claude. Each has its own allowed folders and capabilities, and the log says which agent ran each command.
2. **People and agents are told apart for sure.** A tab you open in CTX.app is yours, with whatever permissions you've (sloppily) granted. An agent never gets those just by running in, or driving, one of your tabs.
3. **Starting an agent always lands it in its own scope.** When `claude`, `codex` or `agy` starts anywhere (a tab you opened, a hook, a launcher), ctx runs it under that agent's profile, because those programs would otherwise inherit their caller's identity.
4. **Software dev:** read/write your home in general, but not Desktop, Documents, Downloads, `~/.ssh`, `~/Context`, or other agents' folders.
5. **Sysadmin is the deliberate exception.** It sees what dev can't (Full Disk Access, system state) through its own launcher, so the general-purpose agent can't change other apps' permissions or delete system files while you're away.
6. **Long term: one macOS user account per agent,** with files and folders granted to it, rather than only sandboxing everything as you.

This matches SPEC.md's principle ("CTX's own processes and shells hold no permissions; permissions live only on narrow, signed launchers chosen by the user") and extends it from "grant per launcher" to "deny by default per agent".

## Tool 1: seatbelt (`sandbox_init` / `sandbox-exec`)

Tested today with scratch folders:

- A deny rule (`(deny file-read* file-write* (subpath …))`) gives `Operation not permitted`, and every child inherits it (zsh → python).
- A profile can close the ctx socket: `(deny network-outbound (literal "/private/var/folders/…/server.sock"))` makes `ctx` fail. The rule must use the `/private/var/…` form of the path; `/var/…` doesn't match.
- **Nesting fails:** `sandbox-exec` inside `sandbox-exec` → `sandbox_apply: Operation not permitted`. Claude Code's own `/sandbox` mode and Codex's default sandbox use Seatbelt, so under a ctx profile those must be off, and ctx's profile is the sandbox (not verified how each agent behaves when its sandbox can't start).
- **launchd is reachable** from inside a profile (`launchctl print gui/501` worked). `launchctl submit`, `open` (LaunchServices) and `osascript` (Apple Events) start work *outside* the sandbox. A profile has to deny those Mach services; which ones break normal dev tools is not verified.
- `sandbox-exec` is marked deprecated but ships in macOS 27 and is what Claude Code, Codex and Gemini CLI use on macOS. Apple can change the profile language at any time without notice.
- Not verified: whether a seatbelt deny on `~/Desktop` stops the TCC prompt or comes after it. Test this with you at the machine (it may show a dialog).

Seatbelt is good at fine-grained denies (paths, sockets, Mach services, network) and needs no root. It's weak as an identity: the process is still uid 501, so anything that escapes the profile (a missed service, a confused deputy) has all of your access.

## Tool 2: a user account per agent

Researched, not tried (it needs `sudo`, and making accounts is your call):

- **Creating them:** `sysadminctl -addUser <name> -roleAccount` (hidden role account, underscore name, UID 200 to 400) or a normal hidden user. No GUI login needed.
- **Identity becomes unforgeable.** The server reads the peer's uid on its socket (`getpeereid`), so "uid 501 = you, uid 4xx = agent dev" can't be faked by a process running as the agent. That answers "who ran this, a person or which agent" at the agent level, by construction.
- **Credentials are separate.** The dev agent has its own HOME: no `~/.ssh`, no Keychain, no `gh` login of yours. Give it a deploy key or a scoped token. Claude Code would log in with `claude setup-token` (long-lived token, exists in 2.1.310) via `CLAUDE_CODE_OAUTH_TOKEN`, since a user with no GUI session has no unlocked login keychain (not verified end to end).
- **It can't touch your session:** no Apple Events to your apps, no killing your processes, no writing your launch agents or `defaults`. Most of the seatbelt escape hatches above close by themselves, because launchd and LaunchServices run per user.
- **Files are granted with ACLs.** `chmod +a "_ctxdev allow list,search,readattr,read,write,append,add_file,add_subdirectory,delete_child,file_inherit,directory_inherit" ~/Workspaces`, plus `search` on `/Users/c`. Inheritance only applies to new files, so existing trees need one recursive pass. Files the agent creates are owned by it; the inherited ACL gives you access back. Git will call those repos "dubious ownership" until `safe.directory` is set.
- **Your home is open to other accounts today.** `/Users/c` is 755, and `~/Context`, `~/Agents`, `~/.claude`, `~/.config` and 52 other folders are world-readable (tested). A new account could read `~/Context`, where your passport and SF86 live. Before any agent account exists, the home has to go to 700 (or 750 with a dedicated group) and get access back through ACLs.
- **Switching uid needs root.** Options: a `sudoers` rule allowing exactly one helper (`ctx-agent-run`) with NOPASSWD, good for a prototype; or a LaunchDaemon helper registered with `SMAppService` that only accepts requests from your ctx server, the durable version (you approve it once in System Settings → Login Items). The PTY can be handed to the agent process as an inherited file descriptor.
- **Costs:** per-agent toolchain state (bun, uv and conda caches, `~/.claude`), and shared tools must be world-executable (Homebrew is). TCC is per user, so an agent account starts with no grants at all, which is the point. Full Disk Access is system-wide, so a launcher granted FDA keeps it under any account.

## Recommendation: both, in layers

1. **Principal = agent.** The server attaches a principal to every client and tab: *you* (uid 501, not under an agent profile), or an agent name. With accounts it comes from the socket's uid; before accounts, from the launcher or profile the process was started under.
2. **Tabs belong to a principal.** A client can drive only tabs of its own principal; you can drive all of them. This closes the socket escape and makes "an agent ran this in my tab" impossible rather than merely logged.
3. **The server spawns a tab under its principal's profile.** `ctx-launch` takes the profile: uid (through the helper) and seatbelt profile (`sandbox_init` before exec). The hook's session tab is then spawned as the agent that asked for it, so routing Bash through ctx can no longer widen access.
4. **Agent programs always start in a profile.** In tabs, ctx's shell integration puts a shim directory first on PATH (`claude`, `codex`, `agy`, … from a configurable list, not hard-coded checks). It picks the profile from config: a folder rule (`~/Agents/<name>` → that agent, everything else → `dev`) or an explicit launcher. `sysadmin` keeps its signed launcher and becomes "an agent profile with extra grants". Running the full path still bypasses the shim, which is fine for *you*; an agent can't do it, because it already runs as its own account.
5. **Seatbelt on top of accounts** for denies inside granted areas (for example, dev may write `~/Workspaces` but not a repo's `.git/hooks`), network rules, and closing other agents' ctx tabs.
6. **CTX.app and your tabs:** your tabs stay uid 501 and may hold whatever you grant (your "sloppy" profile). Moving `ctx-launch` out of the CTX.app bundle into its own small bundle (e.g. "CTX Shell") gives prompts an honest name, keeps CTX.app's own grants off your tabs, and is a one-line choice once agent tabs no longer depend on TCC at all.

Order of work: (a) principal + tab ownership + socket rule in the server (no OS changes); (b) seatbelt profiles applied in `ctx-launch` for agent tabs, which delivers "dev can't read Downloads/Desktop/.ssh" quickly; (c) the uid helper and agent accounts once you've decided the forks below.

## Forks only you can decide

1. **Sysadmin's account.** Run it as you (uid 501, trusted, identified by its launcher, as now), or as its own account with read ACLs on your home? To change *your* settings (`defaults`, `launchctl gui/501`, your launch agents) it has to be you, so as you is the recommendation.
2. **Agent accounts at all, and when.** They need `sudo` once per account, a home-permission change (700 + ACLs), and a privileged helper. Seatbelt-only gets most of the file scoping without any of that, but identity stays inferred.
3. **What dev may read.** Your list: home yes, Desktop/Documents/Downloads no. Proposed defaults beyond that: no `~/.ssh`, `~/Context`, `~/Library` (except caches it needs), `~/.config/gh` and other tokens, other agents' `~/Agents/*`. Confirm or edit.

## Tests that need you at the machine

1. Seatbelt deny on `~/Desktop`: does a prompt still appear?
2. After moving `ctx-launch` to its own bundle: does the prompt name it, and does a CTX.app grant stay out of tabs (permissions checklist items 3 and 4)?
3. One throwaway role account: create it, ACL one folder, run `claude -p` as it with a setup token, then delete the account.

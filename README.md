# CTX — the Charles Terminal Experience

An AI-first, low-memory terminal for macOS. It should feel like Terminal.app or Ghostty, use a
fraction of the RAM, and be fully readable and drivable by AI agents through a CLI a non-programmer
can understand.

Everything is written in Rust.

## The three projects

| Folder      | What it is                                                                 | Spec                              |
|-------------|----------------------------------------------------------------------------|-----------------------------------|
| `ctx/`      | The engine: a background server that owns every shell and records every tab, plus the `ctx` CLI that humans and agents use to list, open, run commands in, read, search, reopen and close windows and tabs. Replaces tmux, and an agent's throwaway shell. | [ctx/SPEC.md](ctx/SPEC.md)         |
| `ctx-app/`  | `CTX.app`, the native macOS window. It holds no shells; it is a viewer and keyboard for the `ctx` server. | [ctx-app/SPEC.md](ctx-app/SPEC.md) |
| `bro/`      | `bro`, autocomplete on steroids. `bro kill that ghostty process` → your next prompt is pre-filled with the command, ready to run. | [bro/SPEC.md](https://github.com/Dissipation-AI/bro/blob/main/SPEC.md)         |

```
                 ┌──────────────┐        ┌──────────────┐       ┌──────────────┐
  human ───────▶ │   CTX.app    │        │  ctx (CLI)   │ ◀──── │ AI agent /   │
  (keyboard,     │ (GUI viewer) │        │              │       │ scripts      │
   mouse)        └──────┬───────┘        └──────┬───────┘       └──────────────┘
                        │  same protocol, same socket   │
                        └──────────────┬────────────────┘
                                       ▼
                              ┌──────────────────┐   spawns, one per tab
                              │   ctx server     │ ───────────────────────▶ zsh ─▶ your commands
                              │ (launchd agent)  │   (each tab's process tree is
                              │ terminal state,  │    its own "responsible process"
                              │ scrollback, log  │    for macOS permissions)
                              └──────────────────┘
                                       ▲
                                       │ reads recent commands + output
                              ┌──────────────────┐
                              │       bro        │ ──▶ your LLM endpoint (e.g. local Qwen)
                              └──────────────────┘
```

## Decisions made so far

1. **Only windows and tabs. No panes.** A window holds an ordered list of tabs. CTX.app may *show*
   several tabs side by side in one window (drag a tab to an edge), but that layout lives only in
   the GUI. The `ctx` server and CLI never know about it, and a selection or copy never crosses
   from one tab into another.
2. **Permissions belong to narrow signed launchers, never to the terminal or its shells.**
   CTX.app and the `ctx` server hold no privacy grants, and tabs are spawned so none could leak
   anyway. Plain shell commands fail closed on protected locations. To grant something (e.g. Full
   Disk Access for a sys-admin agent), you grant a small purpose-built signed launcher that
   disclaims the terminal and stays as the parent of what it runs. This is proven working today,
   in Ghostty, by `~/Agents/sys-admin/bin/sysadmin-agent`. `ctx make launcher` builds such
   launchers from a reviewed template, and ctx shows which tabs run under one. See [ctx/SPEC.md § Permissions](ctx/SPEC.md#permissions).
3. **Agents can read and drive any tab by default, and everything they do is logged and visible.**
   The socket is private to your macOS user, as with tmux. Every action from a client other than
   the GUI goes into an activity log and shows a badge on the tab.
4. **`ctx` commands are English sentences, one vocabulary, no aliases.**
   `ctx run in "Claude - auth refactor" "cargo test"`, `ctx open tab in window 2 named "Dev server"`,
   `ctx list tabs as json`. A verb comes first, then phrases introduced by English words (`in`,
   `at`, `named`, `until`, `as`…) in any order. No noun-subcommand hierarchy and no `--flags`.
   Help and logs always show one canonical order. (`bro` answers to `bro`, `Bro`, `bro,` etc.
   because voice dictation produces those.)
5. **Every tab is saved and can be reopened.** Commands, coloured output, folder and environment
   are recorded as the tab runs (append-only, compressed, written per finished command, so light on
   the SSD). Closed tabs can be read, searched and reopened later, even after a reboot. Tab numbers
   are never reused, so "tab 42" means the same thing forever.
6. **Agents work in tabs.** `ctx run` replaces an agent's throwaway shell with a persistent,
   visible, recorded tab (with an MCP server for Claude Code). Named tabs are shared, so agents can
   share a running dev server or REPL instead of each starting their own.
7. **Tabs are known by folder + a human name.** The name is free text (letters, digits, spaces,
   `-`, `_`), like `Claude - auth refactor`, not a slug.
8. **Tabs show their own timeline** as dimmed event lines (`[reopened 2026-10-11 08:02 after
   reboot]`, `[ssh to deploy@web-1 ended · connection lost]`). Commands are recorded with where they
   ran (`deploy@web-1:/srv/app$ …`), over ssh too. A program can't wipe a tab's history.
9. **Nothing key-like is ever sent to a model**, even a local one, by `bro` or by `ctx ask`.
   Redaction covers env values, history, output and saved tabs.
10. **Written for tokens.** Whole words, labelled numbers, no symbols or abbreviations
    (`within 10 minutes`, not `-t 10m`), bounded output by default, so language models read and
    write `ctx` reliably.
11. **Agents are first-class users, with evidence.** `ctx install instructions for claude|codex|gemini`
    writes a short, generated rules block into the agent's instruction file. Replacing agents'
    built-in shell tools (plugins, extensions, MCP) comes later, and ships per agent only after an
    evaluation shows it doesn't cost speed, tokens or quality. Every command records who ran it
    (you or which agent), searchable but not shown in everyday views. Structured output comes
    `as json` or `as toon` (TOON: shorter for tabular answers; whether it helps agents is
    measured, not assumed).
12. **Separate tools, Unix-style.** `bro` does one thing: intent in, terminal command out.
    `ctx` uses it, when installed, to suggest a fix for a sentence it can't parse (`assist`,
    can be turned off), but never requires it. `ctx ask "…" about tab 212` (answers about a tab,
    with verified evidence lines) is a different job and uses its own, larger model configured
    in `ctx`. `bro` knows nothing about it.
13. **zsh only for v1** (locally; over ssh, remote bash and zsh are both recorded). bash and fish come later.
14. **Names are provisional.** `ctx`, `CTX.app` and `bro` may be renamed later. Keep names in one
   constant per project so a rename is cheap.

## Shared conventions

- **Monorepo of separate tools.** Each top-level folder is its own project with its own Cargo
  workspace, version, changelog, release tags (`ctx-v0.1.0`, `bro-v0.1.0`, `ctx-app-v0.1.0`) and
  package. There's no root Cargo workspace, and any tool can be built, installed and used without
  the others. They work well together through public interfaces only: command lines and
  documented `as json` / `--json` output.
- `ctx-app` is the one exception that links a `ctx` crate (`ctx/ctx-protocol`, the server's wire
  protocol), because it's a GUI for the `ctx` server. Protocol versions are checked on connect.
- **Public tools live in their own repos, linked here as git submodules:** `bro/`
  ([Dissipation-AI/bro](https://github.com/Dissipation-AI/bro)) and `shared/redact/`
  ([Dissipation-AI/redact](https://github.com/Dissipation-AI/redact)). Clone with
  `git clone --recurse-submodules`, or run `git submodule update --init` after a plain clone.
  A tool that depends on a shared crate pins it by git tag (bro uses
  `redact = { git = "…/redact", tag = "v0.1.0" }`) so it also builds outside the monorepo.
- `shared/` holds small library crates used at **compile time** by more than one tool (e.g.
  `shared/redact`, the secret-redaction rules used by `bro` and `ctx ask`). No tool depends on
  another at runtime because of them.
- Config: `~/.config/ctx/config.toml`, `~/.config/bro/config.toml`.
- State/logs: `~/Library/Application Support/ctx/`, `~/Library/Application Support/bro/`.
- Minimum macOS: 14 (Sonoma). Apple Silicon first; Intel builds if they're free.
- Every binary is code-signed and notarized with the same Developer ID so macOS identifies it
  consistently in Privacy & Security.

## Memory targets (the whole point)

Measured as physical footprint (`footprint` / Activity Monitor "Memory"), 15 tabs open with typical
dev use plus one running `top`, 3 windows:

| Component      | Target     | Notes                                                    |
|----------------|------------|----------------------------------------------------------|
| `ctx` server   | < 40 MB    | excluding scrollback above the default budget            |
| CTX.app        | < 80 MB    | most of this is window backing stores, unavoidable on Retina |
| `bro`          | < 10 MB    | short-lived; 0 MB when idle                              |

For comparison, Terminal.app and Ghostty were observed at 400–700 MB, sometimes several GB, with 10-15 empty tabs. This is because they have seperate gpu allocations for each tab, rather than seperate ttys and one display element that is pointed a differing terminal buffers. Scrollback memory is partly unavoidable (and kept compact in ctx); per-tab GPU allocation is pure waste and avoidable.

## Engineering

Each project's spec has its own **Stack** and **Testing** sections. Common rules:

- Rust, edition 2024, toolchain pinned per project. No async runtime, no `clap`, no GUI
  framework beyond AppKit bindings.
- Every dependency justified and checked (`cargo deny`, `cargo audit`); memory, startup and
  binary-size budgets enforced in CI.
- Unit tests beside the code, run on every commit; integration tests per project; CI on GitHub
  Actions macOS (Apple Silicon) runners: `fmt`, `clippy -D warnings`, `test`, `deny`.

## Build order

1. `ctx` server + CLI, headless (usable alone in any terminal, like tmux).
2. `bro` (works in any terminal; gets better inside CTX).
3. `CTX.app`.

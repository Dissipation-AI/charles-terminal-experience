# CTX.app — spec

The native macOS window for CTX. It should feel like Terminal.app or Ghostty: fast, crisp, native
shortcuts. It holds **no shells and no scrollback of its own**. It is a viewer and keyboard for the
`ctx` server (see [../ctx/SPEC.md](../ctx/SPEC.md)). Anything you can do in the app, an agent can do
with the `ctx` CLI, and the app reflects it immediately.

## Goals

1. **Low memory:** < 80 MB with 3 windows and 15 tabs. Hidden tabs cost ~nothing.
2. **Feels native:** Terminal.app keyboard shortcuts, native text input (accents, emoji picker,
   dictation, voice tools like Handy), smooth trackpad scrolling, system light/dark appearance.
3. **Fast:** keystroke-to-pixel latency at or below Ghostty's; 120 Hz on ProMotion displays; no
   flicker in Ink/React TUIs.
4. **Honest about agents:** you can always see when something other than you touched a tab.

## Non-goals

- Panes, split shells, or a tmux-style layout language.
- Settings UI beyond the basics (v1). Config is a file.
- Plugins, AI chat sidebar, or any built-in LLM. (`bro` handles AI assistance at the prompt.)

## Windows and tabs

- One CTX.app window per `ctx` window. `ctx open window` from anywhere opens one; closing the app
  window closes the `ctx` window (with the usual "processes are running" confirmation).
- A tab bar like Terminal.app/Ghostty. Drag to reorder, drag to another window to move, drag out
  to make a new window. All of these are `ctx` operations (`move tab …`), so the CLI stays in sync.
- **Side-by-side tabs (GUI only):** drag a tab onto the left/right/top/bottom edge of the content
  area to show it next to the current one. This produces *tiles* within the window, each showing
  exactly one tab. Rules:
  - Tiles are purely a view. The `ctx` server doesn't know about them; it only knows the window's
    ordered tab list. `ctx` output never interleaves tabs.
  - A selection lives inside one tab. You can never select or copy across a tile boundary, so
    copied text never mixes lines from two tabs.
  - Tile layout is saved per window in the app's state file and restored on relaunch.
  - Closing a tab removes its tile; the neighbour takes the space.
- The app reconnects to all existing `ctx` windows on launch (they survive an app crash).
- **Tab labels** show the tab's name, if it has one, and its current folder, e.g.
  `Dev server — ~/code/site`, shortened from the left when space is tight. A tab without a name
  shows its folder only. A program's terminal title (OSC 0/2) appears in the tooltip and in the
  window title, never in place of the name. Double-click a tab to rename it (same character rules
  as `ctx rename`).
- Tabs opened by an agent carry a small marker with the agent's name (e.g. `claude`) and land in
  the **Agents** window unless the agent picked a window. You can watch that window live, or open
  it later to audit what was run.
- **Closed tabs:** ⌘⇧T reopens the most recently closed tab (`ctx reopen`). The *History* menu
  (⌘Y) is a searchable list of saved tabs, filterable by folder, name, who opened it, and date.
  Selecting one shows its saved commands and output, with colours, read-only. A *Reopen* button
  brings it back. This is the human view of `ctx list closed tabs` / `ctx find`.
- On launch after a reboot or crash, a bar offers "Reopen 7 tabs from last time"
  (`reopen_on_launch`).

## Rendering

The memory goes to window backing stores, not text. A Retina 5K window is ~59 MB *per frame
buffer*, so the buffer count is the main lever.

- **Toolkit:** AppKit via `objc2` bindings (native windows, tab bar, menus, text input). No
  Electron, no web view, no cross-platform GUI toolkit.
- **One text surface per window, whatever the tab count.** Switching tabs doesn't swap in a
  different view. The window's single surface just starts drawing another tab's text. The app
  asks the server for that tab's visible rows (a few KB: ~50 rows × ~200 cells of characters and
  colours), drops the previous tab's rows, and redraws. Tabs that aren't visible cost the app zero
  bytes, and only the server holds their text. Tab switching must still feel instant: < 1 frame,
  and the round trip to a local socket is well under a millisecond.
- **Drawing:** one `CAMetalLayer` per window. Side-by-side tiles are regions drawn into that same
  layer, not extra layers. All windows share **one** `MTLDevice`, **one** command queue and **one**
  glyph atlas for the whole app.
  - `maximumDrawableCount = 2`, `framebufferOnly = true`, 8-bit BGRA.
  - Draw only when the server sends a change or the user scrolls/selects. No continuous render
    loop. Cursor blink uses a timer that redraws just the cursor.
  - When a window is minimised, fully covered or on another Space, release its drawables
    (`NSWindow.occlusionState`).
  - Colours: full truecolor plus the 256/16-colour palettes, bold/italic/underline styles
    (curly/dotted/coloured underlines too), reverse video, and dim. Each cell is drawn from the
    server's `(text, style)` runs, so React/Ink TUIs look exactly as they do in Ghostty.
- **Glyphs:** shaped and rasterised with Core Text, so text looks identical to Terminal.app
  (font smoothing, SF Mono / Menlo defaults, emoji via Apple Color Emoji). The glyph atlas is a
  single texture that starts at 1024×1024 and grows only when needed; least-recently-used glyphs
  are evicted rather than growing without bound.
- **Cell data:** the app keeps only the rows of tabs currently on screen. Scrolling back asks the
  server for rows on demand (with a small read-ahead cache).
- **Fallback:** if Metal proves heavier than expected in the Phase 0 measurement, draw with Core
  Text directly into a layer-backed `NSView` (CPU rendering). Text terminals are cheap enough that
  this may be competitive. Measure both; pick on memory first, latency second.

## Input

- `NSTextInputClient` for full IME, dead keys, emoji picker, and dictation/voice tools that insert
  text.
- Keys are forwarded as key events to the server, which encodes them (xterm or kitty keyboard
  protocol, whichever the program asked for). The app doesn't encode escape sequences itself.
- Option-as-Meta: configurable per side (`left_option_is_meta = true` default), like Terminal.app.
- Mouse: selection, word/line selection, ⌘-click opens links (OSC 8 and detected URLs), and
  mouse reporting to programs that request it (hold ⌥ to select anyway).
- Paste goes through the server's bracketed paste. Pasting more than one line into a shell prompt
  (not a full-screen program) shows a one-line preview first. Configurable.

## Keyboard shortcuts (Terminal.app conventions)

| Shortcut | Action |
|---|---|
| ⌘N | New window |
| ⌘Q | Quit (confirms if commands are running) |
| ⌘C / ⌘V | Copy selection / paste |
| ⌘A | Select all in this tab |
| ⌘T | New tab (same folder as current tab) |
| ⌘W | Close tab |
| ⌘⇧W | Close window |
| ⌘1…⌘9 | Go to tab N in this window |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌘K | Clear scrollback (the saved record is kept) |
| ⌘⇧T | Reopen last closed tab |
| ⌘Y | History of saved tabs |
| ⌘F | Find in this tab |
| ⌘⇧F | Find in all tabs (`ctx find`) |
| ⌘+ / ⌘- / ⌘0 | Font size |
| ⌘⌥← → ↑ ↓ | Move focus between side-by-side tiles |
| ⌘⇧I | Rename tab |
| ⌘⇧A | Activity panel |
| ⌘, | Open the config file |
| ⌃⌘F | Full screen |
| ⌘M, ⌘H, ⌘` | Minimise, hide, cycle windows (standard macOS) |

All shortcuts are listed in the menus (so they're discoverable) and can be rebound in config
(`[app.keys]`). If a terminal program needs a key the app would take, ⌥-less ⌃ combinations
always go to the program, as in Terminal.app.

## Agent visibility

- A small dot badge on a tab when another client (not the app) has typed into it or read it in the
  last 60 seconds. Its colour differs for "typed" and "read only".
- Click the badge (or ⌘⇧A) to open the **Activity** panel: a plain-language list from the server's
  log, e.g. *"claude (in tab 2) typed `npm test` and pressed Enter in tab 4 — 12s ago"*.
- When an agent runs `ctx show "Dev server"`, the app brings that tab forward but doesn't steal keyboard
  focus from another app.

## Permissions

- CTX.app requests **no** privacy permissions (no Full Disk Access, Accessibility, Screen Recording,
  Automation). It reads only its config and state files. Shells are spawned by the `ctx` server
  with their own macOS identity (see [ctx spec § Permissions](../ctx/SPEC.md#permissions)), so
  nothing granted to the app could reach them anyway.
- On first launch, registers the `ctx` server as a LaunchAgent via `SMAppService.agent` and
  installs the `ctx` and `bro` command-line tools (symlinks into `/usr/local/bin` or
  `~/.local/bin`, with consent).
- When a tab's output shows a macOS permission failure (`Operation not permitted` on a protected
  path), show a dismissible one-line hint under it explaining that macOS decided this, not CTX,
  with a button that opens the matching System Settings pane.
- Signed with Developer ID, hardened runtime, notarized. No App Sandbox (it must talk to the
  server's socket and launch it), but no entitlements beyond what that needs.

## Configuration

`~/.config/ctx/config.toml`, `[app]` section. Reloaded on change.

```toml
[app]
font = "SF Mono"
font_size = 13
theme = "system"            # follows macOS light/dark; or a theme file name
left_option_is_meta = true
right_option_is_meta = false
confirm_multiline_paste = true
cursor = "block"            # block | bar | underline
cursor_blink = false
```

Themes: Terminal.app's "Basic" look by default; theme files are TOML colour lists (16 ANSI +
fg/bg/cursor/selection). Ship a few, including a Ghostty-like default.

## Stack

| Concern | Choice | Why |
|---|---|---|
| Language | Rust, edition 2024, pinned stable toolchain | |
| macOS UI | `objc2` + `objc2-app-kit`, `objc2-foundation`, `objc2-quartz-core`, `objc2-metal`, `objc2-core-text` | native AppKit, typed bindings, no Xcode project |
| Rendering | Metal through `objc2-metal` (one device, one atlas); Core Text CPU fallback | measured in Phase 0 |
| Server connection | `ctx-protocol` crate (the one cross-project dependency) | protocol versions checked on connect |
| Config | `toml` + `serde`, file watching via `FSEvents` FFI | |
| Bundling | small `xtask` that builds the `.app`, signs (Developer ID, hardened runtime) and notarizes | reproducible in CI |

No cross-platform GUI toolkit, no web view, no async runtime.

## Testing

**Unit tests** (`cargo test`, every commit; no window server needed):

- layout: tile splitting, closing and resizing; that a selection can't cross a tile;
- selection and copy: word/line selection, wide characters and emoji, wrapped lines joined
  correctly, trailing spaces trimmed;
- glyph atlas: packing, growth, LRU eviction, no duplicate rasterisation;
- input mapping: NSEvent → key event for the server, Option-as-Meta per side, IME composition
  states;
- shortcut table: no two actions share a key; every action appears in a menu.

**Integration tests:** launch the app against a test `ctx` server, drive it via the server
protocol and Accessibility APIs, and compare rendered frames with reference screenshots
(tolerant diff) for a fixed set of screens (truecolor gradient, emoji, box drawing, an Ink app,
vim). Memory and latency budgets (see Acceptance tests) run in CI on Apple Silicon runners.

## Crate layout

```
ctx-app/
  src/app/        AppKit glue: app delegate, windows, tab bar, menus, shortcuts
  src/view/       terminal view: input, selection, scrolling, tiles
  src/render/     Metal renderer, glyph atlas, Core Text shaping (and CPU fallback)
  src/client/     connection to ctx server (ctx-protocol)
  bundle/         Info.plist, icon, entitlements, LaunchAgent plist
```

Build the `.app` bundle with `cargo-bundle` or a small `xtask`. No Xcode project.

## Phases

0. **Measurement spike:** empty window with Metal (2 drawables) vs Core Text CPU drawing. Measure
   footprint at 1, 3 and 10 windows on a 5K display, and latency with `typometer`.
1. Single window, single tab, rendering + input against a running `ctx` server.
2. Tabs, multiple windows, Terminal.app shortcuts, reconnect on launch.
3. Selection, copy, find, links, scrollback scrolling.
4. Side-by-side tiles.
5. Activity badges and panel, permission hints, first-run install flow.

## Acceptance tests

- Claude Code, vim, htop/top, `lazygit`, and an Ink (React) demo app render and behave identically
  to Ghostty side by side (screenshot diff + manual check).
- 15 tabs / 3 windows / `top` running: app < 80 MB, server < 40 MB, total < 25% of Terminal.app's
  footprint for the same workload.
- Copying a selection from a tile never contains text from another tile.
- Killing CTX.app with `kill -9` and relaunching restores every window and tab with scrollback.

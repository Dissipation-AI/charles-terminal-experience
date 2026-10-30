# ctx-skills: results log

Spec: `ctx-skills.toml`. Full reports: `bench/bench report <experiment>` (results/ is git-ignored, so the numbers that matter are copied here).

## 2026-10-25, agy 1.4.7, gemini-3.8-flash-high, 3 reps x 10 tasks x 3 setups (experiment 2026-10-25-ctx-skills-e406)

ctx 0.1.0 at ctx commit 73591a0 (branch ctx-skills), skills at the same commit. 90/90 runs valid, 4 at a time. Oracle self-test (2026-10-25-ctx-skills-1179): 30/30.

| setup | pass rate | median wall s | median tokens | median output+thinking |
|---|---|---|---|---|
| plain | 90% (27/30) | 56 | 138,966 | 4,950 |
| ctx | 100% | 50 | 129,441 | 4,454 |
| ctx-skills | 100% | 54 | 137,417 | 5,310 |

Paired, geometric mean over tasks of the ratio of medians, 95% bootstrap CI:

| comparison | wall time | total tokens |
|---|---|---|
| ctx vs plain | 1.00x [0.78, 1.12] | 0.96x [0.78, 1.12] |
| ctx-skills vs plain | 1.10x [0.87, 1.30] | 1.09x [0.92, 1.27] |
| ctx-skills vs ctx | 1.10x [0.98, 1.33] | 1.14x [0.98, 1.37] |

Findings:

- ctx meets SPEC.md's bar against plain agy: same time and tokens within noise, and better success. The 3 failures are all plain/dev-server: agy kills a background server when it exits; in a ctx tab the server survives (3/3). pick-up-task: ctx 50 s / 146k vs plain 87 s / 279k, because the other agent's tab is there to read.
- The skills don't pay for themselves yet on agy. Against ctx alone they cost ~10% more time and ~14% more tokens (CIs just include 1) and add no success, since ctx alone already passes everything.
- The skills load on the wrong tasks. Loaded in 11/30 runs: dev-server 3/3, interactive-wizard 3/3, pick-up-task 3/3, long-build 1/3, sqlite 1/3, and never on postmortem-debug or slow-load-inspect, where a persistent session should help most. Where they load on a simple task they add ceremony: dev-server 22 s / 49k (ctx) to 44 s / 91k; interactive-wizard 33 s / 63k to 63 s / 98k (opened a second tab, ~5 `ctx wait` and several `ctx read` calls instead of one command).
- Wins with skills are small and probably noise at n=3: postmortem-debug 69 s to 44 s, long-build 374 s to 279 s, both without loading a skill.
- ctx/long-build was slow (median 374 s vs 207 s plain) because of the model, not ctx: tools took ~0 s besides the 151 s build. After building, agy got suspicious, searched the web for the prompt text and inspected `env`, `~` and `bin/`. agy tells the model "A pre-tool hook changed the arguments of this tool call" on every ctx-routed command; that may be the trigger.
- The tasks are at ceiling for success with this model, so they measure time and tokens only. Harder tasks (or a weaker model) are needed to see quality differences.

Not run yet: Claude (needs a token, see README).

## Round 2, 2026-10-25, agy 1.4.7, gemini-3.8-flash-high (spec `ctx-skills-2.toml`, experiment 2026-10-25-ctx-skills-2-1cd9)

Why a round 2: in round 1 agy read each task's source and got around every "slow" or "stateful" part (patched out `time.sleep`, replayed the random seed), so no task needed a persistent terminal. Research on how agy uses skills: its system prompt lists each skill's name, path and description and says "If a skill seems relevant to your current task, you MUST read its SKILL.md"; it then reads the whole file with `read_file` (v0: two files of ~11.7 KB, usually both at once).

New tasks that can't be got around: `ops-console` (an interactive-only client; a daemon gives each connection a fresh random world after a 20 s connect, so the answer chain must be followed in one session), `warehouse-explore` (`load()` takes 25 s and returns a different random snapshot each call; three questions about one snapshot), `tab-dev-server` (ctx only: the user's server fails in a named tab; fix it and restart it there). Daemon code is deleted once running. Oracle passes all 31 cells.

Hypotheses for v1 (`bench/variants/ctx-skills-v1`): (H1) a short SKILL.md (~3.5 KB each, details moved to one-level references) cuts the cost of loading; (H2) telling the agent that its shell is already ctx through the hook, and that plain commands are fine, removes the ceremony (`ctx help`, list/open/wait/read per step); (H3) descriptions keyed on symptoms (needs a TTY, prompts, slow or per-session state; a tab named in the task) trigger where a persistent terminal is needed and not on ordinary work.

| setup | runs | pass | median wall s | median tokens | skill loaded |
|---|---|---|---|---|---|
| plain | 21 | 86% | 43 | 144,900 | - |
| ctx | 24 | 100% | 46 | 142,371 | - |
| skills-v0 | 24 | 100% | 73 | 142,111 | 11/24 |
| skills-v1 | 24 | 100% | 49 | 153,382 | 12/24 |

Against ctx alone: v0 1.10x time [0.91, 1.42], 1.04x tokens; v1 0.85x time [0.71, 1.08], 1.05x tokens [0.89, 1.35], output+thinking 0.85x [0.66, 1.00]. v1 against v0: 0.77x time [0.62, 0.95].

| task | plain | ctx | skills-v0 | skills-v1 |
|---|---|---|---|---|
| ops-console | 264 s | 331 s | 230 s | 127 s |
| tab-dev-server | - | 169 s | 202 s | 127 s |
| warehouse-explore | 350 s | 351 s | 149 s | 161 s |
| dev-server | 0/3 pass, 19 s | 21 s | 49 s | 35 s |
| interactive-wizard | 38 s | 33 s | 84 s | 40 s |
| other three (coding) | 41-46 s | 39-47 s | 36-50 s | 41-49 s |

Findings:

- The skills are needed on `ops-console`: without them, agy with ctx reconnects for every command (a new 20 s session with a new world each time) and then tries to reverse-engineer the daemon (one run took 861 s in a pilot). With v0 or v1 it opens one tab and drives the console with `ctx type` / `wait` / `read`. Plain agy wrote its own socket bridge daemon (264 s).
- v1 is faster than v0 everywhere the skills load (H1, H2 supported), and beats ctx alone on ops-console and tab-dev-server. It still costs time on dev-server (using-ctx loads because its description named a user's dev server; 35 s vs 21 s) and on interactive-wizard (agy ran `ctx help` 4 times and answered one prompt per call, ignoring "type them all at once").
- warehouse-explore: no skill loaded in any setup; agents dumped the snapshot to a JSON file and queried that, which is fine. Times varied 117-559 s because the random data had ties (several customers with the same most cancellations) and agents went looking for a "perfect" snapshot; round 3 makes the answers unique. The skills' advantage there is noise.
- Harness issues found and fixed during the round: agents read the harness's files in the run folder (driver, setup log, call log), now beside it in `<id>.run/`; agents that search `/` reached autofs `/home` and made macOS show "ctx-launch would like to access files on a network volume" (now denied in the sandbox); agy's quota (~65 runs, then 429 with "Resets in 1h17m") now pauses the queue until the reset, and a 429 mid-run is an infra error, not a fail (5 runs reclassified).

## Round 3, 2026-10-25, agy 1.4.7, gemini-3.8-flash-high (spec `ctx-skills-3.toml`, experiment 2026-10-25-ctx-skills-3-ab0b)

v2 (`bench/variants/ctx-skills-v2`) changes two things from v1: using-ctx's description drops "a user's dev server" and says it isn't needed for ordinary commands or servers you start; persistent-terminals leads with a one-call recipe for a wizard whose answers are known (open tab, run, type every answer, wait until idle, read) and says the sentences are complete, no `ctx help` needed. Typed-ahead answers were tested first: a wizard reading with `input()` takes them in order (3/3).

72 runs, 100% pass in every setup, no quota pause.

| comparison | wall time | total tokens | output+thinking |
|---|---|---|---|
| v1 vs ctx | 0.87x [0.73, 1.07] | 1.03x [0.81, 1.14] | 0.89x [0.72, 1.10] |
| v2 vs ctx | 0.78x [0.71, 0.91] | 0.92x [0.82, 1.04] | 0.79x [0.68, 0.95] |
| v2 vs v1 | 0.90x [0.76, 1.09] | 0.89x [0.83, 1.12] | 0.89x [0.74, 1.11] |

| task | ctx | v1 | v2 | v2 loaded |
|---|---|---|---|---|
| ops-console | 404 s | 151 s | 132 s | persistent-terminals 3/3 (+using-ctx 1) |
| tab-dev-server | 203 s | 160 s | 131 s | using-ctx 3/3 |
| interactive-wizard | 53 s | 41 s | 37 s | persistent-terminals 3/3 |
| dev-server | 24 s | 53 s | 24 s | none |
| warehouse-explore | 145 s | 126 s | 130 s | none |
| coding tasks (3) | 41-48 s | 37-47 s | 43-50 s | none |

- Both v2 hypotheses held: using-ctx stopped loading on dev-server (v1 loaded it 2/3, up to 127 s), and the wizard went to one ctx call (7 tool calls in all, vs v1's 8-9 with per-prompt waits and four `ctx help` calls).
- Triggering is now what was wanted: persistent-terminals only where a program needs a terminal across calls, using-ctx only where the task names a tab, nothing on coding tasks.
- Remaining time on tab-dev-server is the model's own investigation (git log, `ctx find`, reading ctx's activity log), not ctx steps.
- Caveat: v2's examples were the benchmark's own tasks ("Console - ops", `./configure` with billing/9040, "Dev server - shop"). Round 4 tests a v3 with generic examples, and two held-out tasks.

## Round 4, 2026-10-26, agy 1.4.7, gemini-3.8-flash-high (spec `ctx-skills-4.toml`, experiment 2026-10-25-ctx-skills-4-409a)

v3 is v2 with every example made generic ("Install"/`./install.sh`, "psql - orders", "Dev server - site"), so no example matches a benchmark task. Two held-out tasks were written after the skills: `db-setup-wizard` (TTY-only installer whose later prompts depend on a one-time code it prints, so answers can't all be typed ahead) and `kv-console` (another slow, per-session console). The 14 tasks include round 1's four where a terminal isn't needed or agy gets around the slow part.

126 runs; 2 quota hits, retried. ctx alone 98% pass (one kv-console timeout), v2 and v3 100%.

| comparison | wall time | total tokens | output+thinking |
|---|---|---|---|
| v2 vs ctx | 0.75x [0.70, 0.88] | 0.93x [0.83, 1.07] | 0.71x [0.65, 0.82] |
| v3 vs ctx | 0.76x [0.69, 0.87] | 0.95x [0.83, 1.04] | 0.73x [0.66, 0.83] |
| v3 vs v2 | 1.01x [0.88, 1.13] | 1.01x [0.88, 1.12] | 1.03x [0.89, 1.14] |

| task | ctx | v2 | v3 |
|---|---|---|---|
| kv-console (held out) | 2/3, 893 s | 167 s | 166 s |
| db-setup-wizard (held out) | 354 s | 82 s | 116 s |
| ops-console | 487 s | 116 s | 123 s |
| tab-dev-server | 209 s | 149 s | 139 s |
| pick-up-task | 57 s | 40 s | 38 s |
| dev-server | 18 s | 23 s | 39 s |
| postmortem-debug | 57 s | 73 s | 67 s |
| sqlite-investigation | 336 s | 436 s | 414 s |
| slow-load-inspect, warehouse, 4 coding tasks | within ~10% | | |

- (a) held: generic examples (v3) perform the same as task-shaped ones (v2). The gain isn't copying.
- (b) held: on both held-out tasks persistent-terminals loaded 6/6 and cut time 2-5x. ctx alone reconnects per command on kv-console and timed out once.
- (c) mostly held: no loads on postmortem-debug, sqlite-investigation or warehouse; slow-load-inspect loaded 2/6. The slower medians on postmortem-debug and sqlite-investigation come with no skill load, so they are run-to-run noise on long open-ended tasks, not skill cost.
- Mis-trigger left: dev-server ("start it so that it keeps running after you finish") loaded a skill in 3/6 runs, after 0/3 in round 3; each load adds 15-20 s and v3 read a reference file too. "Keeps a program open" and "persistent" in the name match a server that keeps running. Round 5 tests descriptions that say what the skill does to a program (run it in a tab and type into it) and a rename to `interactive-programs`.

## Round 5, 2026-10-26, agy 1.4.7, gemini-3.8-flash-high (spec `ctx-skills-5.toml`, experiment 2026-10-26-ctx-skills-5-5773)

Trigger wording only. v4a: descriptions say what the skill does to a program (run it in a tab and type into it) and drop "persistent", "stays open", "servers". v4b: v4a with persistent-terminals renamed `interactive-programs`.

72 runs, all passed, no quota hit.

| comparison | wall time | total tokens | output+thinking |
|---|---|---|---|
| v4a vs v3 | 0.87x [0.77, 1.03] | 0.89x [0.77, 1.14] | 0.91x [0.78, 1.04] |
| v4b vs v3 | 0.88x [0.77, 1.03] | 0.91x [0.78, 1.19] | 0.87x [0.77, 1.05] |
| v4b vs v4a | 1.01x [0.86, 1.17] | 1.02x [0.85, 1.25] | 0.96x [0.83, 1.18] |

- Loads on the tasks that need them: 3/3 in every setup (db-setup-wizard, interactive-wizard, ops-console, tab-dev-server). None on fix-failing-test, postmortem-debug or slow-load-inspect.
- dev-server: v3 loaded skills 2/3 (49 s), v4a 2/3 (35 s), v4b 1/3, using-ctx only (28 s). With the rename, persistent-terminals/interactive-programs never loaded there.
- The remaining using-ctx loads come after agy's first command shows the hook note: it runs `which ctx` or `ls`, then reads using-ctx/SKILL.md. The description lists ctx-related triggers, and the hook makes ctx visible on every task. Round 6 tests saying in the description that the hook note is expected.
- None of the overall differences are significant at n=3 per cell.

## Round 6, 2026-10-26, agy 1.4.7, gemini-3.8-flash-high (spec `ctx-skills-6.toml`, experiment 2026-10-26-ctx-skills-6-1c68)

Load rates at 6 reps. v4c is v4b plus a sentence in using-ctx's description: the hook note is expected, and a server started in the background keeps running without the skill.

72 runs, all passed. Loads (using-ctx / terminal skill, out of 6):

| task | v3 | v4b | v4c |
|---|---|---|---|
| dev-server | 3 / 3, 37 s | 1 / 0, 20 s | 2 / 0, 21 s |
| tab-dev-server | 6 / 0, 134 s | 6 / 0, 126 s | 6 / 0, 133 s |
| pick-up-task | 6 / 0, 39 s | 6 / 0, 41 s | 6 / 0, 39 s |
| db-setup-wizard | 3 / 6, 75 s | 3 / 6, 78 s | 1 / 6, 77 s |

- The rename holds at n=6: the terminal skill never loaded on dev-server under v4b or v4c (rounds 5-6 combined: 0/15, vs 5/9 for v3). dev-server time is back to ctx alone's (round 4: 18 s).
- (a) didn't hold: v4c's sentence didn't lower using-ctx loads on dev-server (2/6 vs 1/6). It stays out.
- (b) held: necessary loads were 6/6 in every setup.

## Result

v4b is ported to `ctx/integrations/ctx-skills` (ctx branch `ctx-skills`, not pushed): short SKILL.md files with details in references, one-call recipes for wizards and console rounds, generic examples, and persistent-terminals renamed `interactive-programs`. Against ctx alone on agy (round 4, v3 ≈ v4b): 0.75x wall time, 0.71x output+thinking tokens, 98% → 100% pass; 2-5x faster on consoles and wizards, including the two held-out tasks.
Open: an occasional using-ctx load on a plain server task (1-2 in 6, ~20 s). Claude hasn't been run on v4b yet; due in the weekly Claude run.

## Handoff to slopslinger, 2026-10-27

The loop continues on slopslinger (Debian 13), in `~/ctx-bench/repo`, from a Claude session in tmux session `ctx-bench`.

State at handoff:
- ctx builds and runs on Linux with ctx branch `linux-build` (2 commits on top of `ctx-skills`, not pushed: ctx CI runs on push, ask first). The Seatbelt calls in `ctx-launch` and `ctx shim` are macOS only; `ctx-helper` doesn't build on Linux and the bench doesn't need it. Build: `. ~/ctx-bench/env.sh; cd ctx && cargo build --release -p ctx -p ctx-launch -p ctx-server` (needs Zig 0.16, at `$ZIG`). A smoke test (server, open tab, run, type into python, wait, read) passed.
- The bench has a bubblewrap backend (`benchlib/sandbox.py`, `LINUX`), untested on the box. It needs `sudo apt install bubblewrap zsh lsof expect sqlite3` (the user runs it) and an agy login (`~/.gemini/antigravity-cli/antigravity-oauth-token`).
- Use the newest agy: run `agy update` before each round (runs record agent_version). At handoff that is 1.4.8; rounds 1-6 ran 1.4.7 on macOS, so start with a fresh baseline (ctx vs current skills) rather than comparing across machines.

Next:
1. Oracle pass on every task (`./bench run <spec> --agent oracle`); fix what's macOS-specific (tasks use `lsof`, `expect`, `shasum`; the runner's cleanup uses `lsof +D`).
2. Check under bwrap that ctx tabs open and the hook routes agy's commands (the invalid-run check flags a ctx setup with no `ctx run`), and that runs can't read the real home.
3. A baseline round on Linux: ctx vs `ctx-skills-v4b` on the 14 round-4 tasks, 3 reps.
4. Keep iterating: open item is the occasional using-ctx load on plain server tasks (rounds 5-6); also try harder held-out tasks (ssh-like, debugger). Write each round here, commit and push the monorepo (no CI). Port a winner into `ctx/integrations/ctx-skills` on `ctx-skills`, don't push ctx without asking.

## Round 7, 2026-10-27, slopslinger (Debian 13, bubblewrap), agy 1.4.8, gemini-3.8-flash-high (spec `ctx-skills-7.toml`, experiment 2026-10-27-ctx-skills-7-96db), stopped at 65 of 84

Linux port first: oracle 44/44 on `ctx-skills.toml` (15 tasks x plain/ctx/ctx-skills) and 28/28 on `ctx-skills-7.toml`, under bwrap. Harness fixes: host info from /etc/os-release and /proc; the fake home gets `.profile`/`.bash_profile`/`.zprofile` putting the run's `bin/` back on PATH, because ctx opens tabs in the user's login shell (bash here) and Debian's /etc/profile overwrites PATH (macOS's path_helper keeps it). Without that, `which ctx` failed in every tab and agy symlinked ctx into `.ctx/data/launchers/bin` itself (interactive-wizard 71 s / 176k, then 37 s / 93k after the fix). The sandbox hides /home and /tmp; a sandboxed process sees other processes' command lines in `ps` but not their root, cwd or environ.

Then the baseline, ctx vs v4b on round 4's 14 tasks. agy's quota on this account resets after ~16 h, not ~1 h as on the Mac: it ran out at 65 runs. Stopped there because two Linux-only problems showed up that touch both setups:

- **ctx: history expansion in agent tabs.** The hook types agy's commands into an interactive bash, so `!` expands. `python3 -c "...; print('All tests passed!')"` failed with "event not found" and `ctx run` waited until "didn't start within the time limit"; agy then waited 15 min on a background task that never ended (v4b/fix-failing-test 900 s; the 94 s run loaded using-ctx after the resulting "Tab 1 is running bash" message; ctx/fix-failing-test 98 s). In a repro, `echo "a!b"` silently ran a command from `~/.bash_history`. zsh reports it ("the shell didn't run it") but doesn't run it either. agy's own shell (`bash -c`) never expands, so through ctx the same command behaved differently. Fixed on ctx `linux-build` (3d02c0e, local): tabs an agent opens set `+H` (bash) / `no_bang_hist` (zsh).
- **Tasks: agents read the daemons' memory.** `kernel.yama.ptrace_scope` is 0 here, so an agent can read `/proc/<pid>/mem` of the task daemon (same user, same sandbox; macOS forbids it). kv-console runs (ctx 2, v4b 1) scraped the daemon's heap for 3-6 minutes and found its source text. The four daemons now `prctl(PR_SET_DUMPABLE, 0)` on Linux: maps, mem, cwd and environ are denied; oracle still passes.

Partial numbers (61 valid runs; ctx 94% pass, the 2 fails are ctx/kv-console and ctx/ops-console timeouts as in round 4):

| comparison | wall time | total tokens | output+thinking |
|---|---|---|---|
| v4b vs ctx | 0.81x [0.68, 0.90] | 0.86x [0.76, 0.93] | 0.72x [0.65, 0.79] |

| task | ctx | v4b |
|---|---|---|
| db-setup-wizard | 431 s (1 run) | 77 s |
| ops-console | 1/2, 650 s | 190 s |
| kv-console | 1/2, 687 s | 339 s (memory scraping) |
| interactive-wizard | 44 s | 32 s |
| pick-up-task | 55 s | 40 s |
| tab-dev-server | 207 s | 168 s |
| dev-server | 36 s | 20 s (no skill load) |
| fix-failing-test | 82 s | 497 s (`!` bug, 900 s run) |
| other 6 | within noise | |

- Even with both problems, v4b's gain over ctx alone carries over to Linux and agy 1.4.8: 0.81x time, 0.72x output+thinking (round 4 on macOS: 0.76x, 0.73x).
- Loads as on macOS: interactive-programs on every wizard/console run, using-ctx on tab-dev-server and pick-up-task, none on dev-server (1 run) or the coding tasks except the one forced by the `!` bug.
- Remaining waste with v4b on consoles: starting a console whose prompt isn't known yet (kv-console: three bare `ctx read` polls and an agy timer while it connects), `ctx help wait` / `ctx help read` despite "the sentences are complete" (kv-console 2/2 runs), and a shell `for` loop of `ctx type` calls that agy moved to the background.

## Round 8, 2026-10-28, slopslinger, **agy 1.4.9** (not 1.4.8), gemini-3.8-flash-high (spec `ctx-skills-8.toml`, experiment 2026-10-28-ctx-skills-8-51b3)

Version note: `agy update` before this round installed 1.4.9. The decision since then is to keep agy at 1.4.8 and not update before rounds. 1.4.8 couldn't be reinstalled here: the release URL has a build id (`antigravity-cli/1.4.9-4962164969177088/linux-x64/...`), the manifest only gives the latest, and the bucket can't be listed. If the Mac's update log has the 1.4.8 build id, the linux-x64 path with that id is worth trying. agy also updates itself in the background; `AGY_CLI_DISABLE_AUTO_UPDATE=1` is now set in `~/ctx-bench/env.sh` and in every run's environment. Versions 1.4.7 (Mac, rounds 1-6), 1.4.8 (round 7) and 1.4.9 (round 8) are treated as minor changes, so rounds compare across them, with the version noted.

ctx 3d02c0e (agent tabs: no history expansion), task daemons not dumpable. v5 = v4b plus three changes to interactive-programs (+750 bytes): how to start a program whose prompt you don't know yet (wait until quiet for 5 s, read, then wait for the prompt, "most end in `> `, `# ` or `: `"), the read/wait phrases inline, and "one multi-line `type`, never a shell loop of `ctx type`". New held-out task `mq-console`, written after v5: interactive-only, a silent 12 s connect, a `(mq) ` prompt that v5's hint doesn't cover, and per-queue dead-letter counts and replay tokens only in the session. 9 tasks x 3 setups x 2 reps, 54 runs; 4 quota hits retried. ctx alone 94% (one kv-console timeout), v4b and v5 100%.

| comparison | wall time | total tokens | output+thinking |
|---|---|---|---|
| v4b vs ctx | 0.54x [0.46, 0.62] | 0.86x [0.79, 0.95] | 0.58x [0.49, 0.71] |
| v5 vs ctx | 0.62x [0.52, 0.72] | 0.96x [0.87, 1.06] | 0.67x [0.58, 0.83] |
| v5 vs v4b | 1.14x [0.95, 1.37] | 1.11x [1.01, 1.23] | 1.16x [1.01, 1.35] |

| task | ctx | v4b | v5 |
|---|---|---|---|
| mq-console (held out) | 612 s | 169 s | 133 s |
| kv-console | 1/2, 645 s | 228 s | 229 s |
| ops-console | 471 s | 308 s (115, 499) | 263 s (143, 381) |
| db-setup-wizard | 525 s | 102 s | 111 s |
| interactive-wizard | 51 s | 35 s | 42 s |
| tab-dev-server | 215 s | 141 s | 159 s |
| pick-up-task | 68 s | 44 s | 43 s |
| dev-server | 26 s | 33 s | 113 s (57, 168) |
| fix-failing-test | 47 s | 44 s | 45 s |

- (a) held: no command stalled on `!` (5 runs typed one, all ran), and fix-failing-test is ~45 s in every setup (round 7 v4b: 497 s). No run probed `/proc/<pid>/mem`.
- (b) partly: v5 removed the bare `ctx read` polls after starting a console (v4b kv-console 1-2 per run, v5 0) and `ctx help` on mq-console (v4b 1 per run, v5 0), but not on kv-console (1-2 in both). Faster on mq-console and ops-console, not on kv-console. Overall v5 isn't better than v4b: 1.14x time with a CI over 1, and +11% tokens.
- (c) held: on the held-out mq-console both skill versions load interactive-programs 4/4 and are 3.6-4.6x faster than ctx alone (612 s; it reconnected for each command, 13-16 agy background tasks per run). v5 used `wait until ... is quiet` and the right prompt after reading the screen; the `(mq) ` prompt didn't trip it.
- (d) didn't hold for v5: using-ctx loaded on dev-server 2/2 (v4b 0/2), though v5 didn't change using-ctx. The 168 s run is the model investigating its environment: `ps aux`, then the harness's files beside the run folder (driver.zsh, ctx-calls.log, the hook config), then the skill files and `ctx help` 4 times. The load followed the investigation, so at n=2 this is noise from agent suspicion, not the skill text.
- Larger gap to ctx than round 7 (0.54x vs 0.81x) because this task set is mostly the tasks where skills matter, not because the skills improved.
- Not adopted: v5's console changes help where a prompt is unknown (mq-console) but cost a little elsewhere. Next is cutting the environment snooping that adds noise to every setup: `ps aux` in the sandbox shows the harness (`bench run experiments/...` in tmux, the driver's path), which invites investigation.

## Round 9, 2026-10-28, slopslinger, agy 1.4.9, gemini-3.8-flash-high (spec `ctx-skills-9.toml`, experiment 2026-10-28-ctx-skills-9-c5bb)

Harness: each run gets its own pid namespace (bwrap `--unshare-pid`), bwrap's arguments go through a file descriptor, and the driver is read from stdin, so `ps` in a run lists only the run's processes and no command line names the harness. The driver stays up after the agent until the harness has run check.sh (the namespace ends with it); tab-dev-server's check compares namespace pids. v6 = v4b plus only v5's paragraph on starting a program whose prompt isn't known yet (wait until quiet for 5 s, read, then wait for the prompt); no inline grammar, no loop sentence.

54 runs. Three hit agy's API with `INVALID_ARGUMENT (code 400)` within one minute, in three setups, one after 6 s with no tokens; reclassified as infra errors and retried (the marker is now an infra error). All 54 pass after retries.

| comparison | wall time | total tokens | output+thinking |
|---|---|---|---|
| v4b vs ctx | 0.61x [0.57, 0.66] | 0.96x [0.88, 1.03] | 0.58x [0.53, 0.64] |
| v6 vs ctx | 0.55x [0.52, 0.60] | 0.92x [0.88, 0.97] | 0.52x [0.48, 0.57] |
| v6 vs v4b | 0.90x [0.85, 0.96] | 0.97x [0.91, 1.04] | 0.90x [0.84, 0.97] |

| task | ctx | v4b | v6 |
|---|---|---|---|
| mq-console (held out) | 523 s | 149 s | 112 s |
| kv-console | 587 s | 164 s | 151 s |
| ops-console | 513 s | 155 s | 141 s |
| db-setup-wizard | 291 s | 86 s | 83 s |
| dev-server | 23 s | 49 s (using-ctx 1/2) | 22 s (0/2) |
| tab-dev-server | 155 s | 168 s | 166 s |
| pick-up-task | 54 s | 40 s | 52 s |
| interactive-wizard, fix-failing-test | 29-46 s, equal | | |

- (b) held: v6 is faster than v4b on all three consoles and on the whole set (0.90x, CI below 1), without v5's costs. The paragraph does what it says: no bare `ctx read` polls after starting a console (v4b: 2 in one kv-console run), and on mq-console (`(mq) ` prompt, not in the hint) v6 waited for quiet, read the screen and went on. v6 is the new best variant.
- (c) held for v6 (using-ctx 0/2 on dev-server), not for v4b (1/2, 56 s). Rounds 5-9 together: the occasional using-ctx load on dev-server remains at about 1 in 4-6 runs for any variant, and costs 20-30 s when it happens.
- (a) partly: runs that ran `ps` stayed common (26/54 vs 29/54), but runs that read the harness's files went from 9/54 to 5/54, all ctx-alone runs on long console tasks. They didn't find them through `ps` anymore: `ls /tmp/ab` showed `<id>.run` beside the run folder, and the `bin/ctx` shim named its log there. Since then the harness's files appear inside the sandbox at `/var/tmp/.r`, not beside the run folder (oracle 9/9; an agy cell installs the plugin from there).
- The gap to ctx alone is mostly the consoles, where ctx alone reconnects for every command (13-18 agy background tasks per run).

Note, 2026-10-29: `~/.local/bin/agy` updated itself to 1.4.10 at 01:14 despite `AGY_CLI_DISABLE_AUTO_UPDATE` in our environment. Another project's Claude session on this machine (`~/oracle`) runs agy with the real home, and its agy did the update. All of round 9 ran 1.4.9 (checked per run); round 10's first attempt (2026-10-29-ctx-skills-10-3c84, 5 runs on 1.4.10) was stopped and discarded. The bench now runs its own pinned copy, `BENCH_AGY=~/ctx-bench/agy/1.4.9/agy` (set in `~/ctx-bench/env.sh`; downloaded by its release URL and checked against the manifest's sha512). That project probably shares the agy account's quota too.

## Round 10, 2026-10-29, slopslinger, agy 1.4.9 (pinned copy), gemini-3.8-flash-high (spec `ctx-skills-10.toml`, experiment 2026-10-29-ctx-skills-10-1260)

Confirmation of v6 against v4b on round 4's 14 tasks plus mq-console, 2 reps, no ctx-alone setup. 60 runs, all pass; 5 runs hit agy's `INVALID_ARGUMENT (code 400)` and were retried automatically (the new infra marker).

| comparison | wall time | total tokens | output+thinking |
|---|---|---|---|
| v6 vs v4b | 0.94x [0.84, 1.09] | 1.09x [0.96, 1.19] | 1.06x [0.95, 1.15] |

| task | v4b | v6 |
|---|---|---|
| mq-console | 159 s | 240 s (123, 355) |
| kv-console | 212 s | 196 s |
| ops-console | 148 s | 158 s |
| db-setup-wizard | 140 s | 104 s |
| dev-server | 36 s | 70 s (46; 92 with using-ctx) |
| slow-load-inspect | 511 s (one run 900+) | 76 s |
| other 9 | within ~15% | |

- (a) didn't hold cleanly: 0.94x, CI includes 1. Over rounds 9 and 10, v6 is no worse than v4b and better on kv-console and db-setup-wizard both times; mq-console and ops-console went one way in round 9 and the other in round 10. The v6 mq-console run at 355 s lost its time to a ctx problem, not the skill (below). The port (ctx-skills 219c16d) stays: the paragraph removed the bare-read polls in both rounds (v4b kv-console 1-2 per run in rounds 8-10, v6 0), and it's 340 bytes.
- (b) held: on the seven tasks that need no terminal, loads and times are the same for v4b and v6 (interactive-programs never loaded there).
- (c) held: no run read the harness's files (0/60, from 9/54 in round 8 and 5/54 in round 9).
- using-ctx on dev-server: v6 1/2 (92 s). Rounds 5-10 combined, for every variant: about 1 in 4.
- **ctx: an incomplete command hangs the tab.** The 355 s run typed `ctx read last 30 lines in "MQAdmin` (no closing quote) through the hook. In an interactive shell that leaves bash (`>`) or zsh (`dquote>`) at its continuation prompt: the command never starts, the hook's call waits until its limit (agy put it in the background and polled it for minutes), and the next command typed there lands inside the open quote. agy's own `bash -c` fails at once. Rounds 7-10 had 2 such runs (counted from ctx's activity log, which keeps the full command; agy's transcript truncates long ones). Fixed on ctx `linux-build` (ac3c0b9, local): `ctx run` first checks the command with the tab's shell (`-n`) and, if it is incomplete, runs nothing and says so with the shell's message. bash: unclosed quotes, unfinished `if`/`for`/braces and here-documents; zsh: unclosed quotes only (zsh doesn't tell an unfinished `if` from other parse errors).

## Round 11, 2026-10-29, slopslinger, agy 1.4.9 (pinned copy), gemini-3.8-flash-high (spec `ctx-skills-11.toml`, experiment 2026-10-29-ctx-skills-11-a917)

ctx ac3c0b9. Round 9's tasks with fix-failing-test replaced by the held-out `jobs-dashboard` (a curses dashboard). 54 runs; 3 agy 400s retried. Fails: ctx alone on jobs-dashboard and kv-console (timeouts), v6 on jobs-dashboard (timeout).

| comparison | wall time | total tokens | output+thinking |
|---|---|---|---|
| v4b vs ctx | 0.55x [0.48, 0.63] | 0.82x [0.73, 1.00] | 0.60x [0.51, 0.89] |
| v6 vs ctx | 0.48x [0.41, 0.55] | 0.74x [0.66, 0.91] | 0.49x [0.40, 0.73] |
| v6 vs v4b | 0.88x [0.74, 1.00] | 0.90x [0.83, 0.97] | 0.81x [0.70, 0.91] |

| task | ctx | v4b | v6 |
|---|---|---|---|
| jobs-dashboard (held out) | 1/2, 714 s | 2/2, 275 s | 1/2, 567 s |
| mq-console | 718 s | 254 s | 119 s |
| kv-console | 1/2, 901 s | 249 s | 200 s |
| ops-console | 781 s | 167 s | 147 s |
| db-setup-wizard | 241 s | 143 s | 116 s |
| dev-server | 30 s | 57 s | 39 s |
| tab-dev-server, pick-up-task, interactive-wizard | | equal | |

- (b) held: v6 vs v4b 0.88x time [0.74, 1.00], 0.90x tokens [0.83, 0.97], 0.81x output+thinking; faster on every console and wizard. Rounds 9-11 together: v6 is the better variant (0.90x, 0.94x, 0.88x).
- (c) held: no run typed an incomplete command (checked against ctx's activity log).
- (a) jobs-dashboard didn't measure what it was meant to. `./jobs` was readable Python that spoke a JSON protocol to the scheduler, so agents read it and restarted the job over the socket instead of using the dashboard: 3 of the 4 passing runs used the dashboard (v4b 6 and 13 `ctx press`, v6 5), ctx alone used the socket. Rewritten for the next round: the scheduler draws the screen itself (alternate screen, every field at its own cursor position) and `./jobs` only relays a raw terminal, like the consoles' clients. Oracle now drives it on a pty and passes.
- **ctx: `wait until … shows` missed text on a full-screen program's screen.** The failing v6 jobs-dashboard run waited for `"tab: queue"`, which was on the screen, timed out after a minute, and the model then spent the rest of the run looking at processes. curses draws with cursor moves, so the text never came through as a line of output, and `shows` only looked at output lines. Fixed on ctx `linux-build` (174dc7b, local): while a full-screen program is in front, `shows` also searches its screen. Tested on the dashboard: `"tab: queue"`, `"[nightly]"`, `"page 1/3"` and, after `press tab`, `"[hourly]"` all match; absent text still times out.

## Round 12, 2026-10-30, slopslinger, agy 1.4.9 (pinned copy) (spec `ctx-skills-12.toml`), and stop

Round 11 repeated with ctx 174dc7b and the redrawn jobs-dashboard. 54 runs, 3 infra errors retried.

| comparison | wall time | total tokens | output+thinking |
|---|---|---|---|
| v4b vs ctx | 0.46x [0.42, 0.52] | 0.76x [0.68, 0.89] | 0.47x [0.41, 0.63] |
| v6 vs ctx | 0.58x [0.48, 0.67] | 0.86x [0.74, 1.02] | 0.52x [0.43, 0.71] |
| v6 vs v4b | 1.27x [1.06, 1.42] | 1.14x [0.99, 1.26] | 1.11x [0.97, 1.22] |

- v6's lead over v4b reversed (rounds 9-12: 0.90x, 0.94x, 0.88x, 1.27x). Differences between tuned variants are at the level of run-to-run noise at 2 reps, and every task, held-out ones included, was written by the same sessions that wrote the skills.
- What held in every round on both machines: skills vs ctx alone, about 0.5-0.8x time and 0.5-0.7x output tokens, mostly from consoles and wizards, held-out tasks included.

Stopped here (user, 2026-10-30): more tuning against these tasks risks fitting the skills to them. Keep v4b (ctx `ctx-skills`, pushed); 219c16d (the v6 port) stays unpushed. The ctx fixes on `linux-build` (3d02c0e history expansion, ac3c0b9 incomplete commands, 174dc7b `shows` on full-screen screens) are general ctx bugs, independent of the skills; pushing them needs the user's OK. Further evidence should come from real use, not more bench tasks.

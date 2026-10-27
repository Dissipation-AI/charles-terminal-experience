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

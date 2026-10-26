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

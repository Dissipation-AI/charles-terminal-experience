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

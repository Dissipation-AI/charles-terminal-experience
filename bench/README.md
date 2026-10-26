# bench

Experiments that compare agent setups on the same tasks. Each run is one headless agent session in its own sandbox; every run is recorded in `results/bench.sqlite` with what went in (`vars`), what versions were involved (`env`) and what came out (`outcomes`).

The first experiment, `experiments/ctx-skills.toml`, asks two questions: does ctx as the agent's shell cost time or tokens compared with the agent's own shell, and do the ctx-skills plugin's skills pay for their tokens on top of ctx.

## Running

```sh
bench/bench run bench/experiments/ctx-skills.toml --agent agy          # the main target
bench/bench run bench/experiments/ctx-skills.toml --agent claude       # occasional (uses Claude quota)
bench/bench run bench/experiments/ctx-skills.toml --agent oracle       # harness self-test, no tokens
bench/bench run ... --task long-build --setup ctx --reps 1 --jobs 2 --keep --dry-run
bench/bench run ... --resume 2026-10-25-ctx-skills-ab12                # retry infra errors, fill gaps
bench/bench report [EXPERIMENT] [--baseline plain] [--save]
bench/bench reparse EXPERIMENT                                        # re-read transcripts after changing a parser
bench/bench list
bench/bench show RUN_ID
bench/bench sql "SELECT setup, task, passed, wall_seconds, total_tokens FROM runs WHERE valid"
```

`bench` is a uv script (stdlib only). ctx setups need a release build of ctx (`cargo build --release` in `ctx/`); the run records the binary's hash and the ctx commit.

Claude needs a long-lived token, kept out of your own login: run `claude setup-token` and save the token in `~/.config/ctx-bench/claude-oauth-token` (chmod 600). agy uses a copy of `~/.gemini/antigravity-cli/antigravity-oauth-token`; nothing to set up while you're logged in to agy.

## What a run is

1. A fresh folder `/private/tmp/ab/<id>/`: a fake `HOME` (the agent's own empty config plus a copy of its credentials), the task's working folder (named for the task's project, e.g. `shop`), `bin/` with only the tools the setup provides, and `TMPDIR`. The harness's own files for the run (driver script, transcript, logs, plugin sources) go in `/private/tmp/ab/<id>.run/` beside it, so an agent looking around its folder doesn't find them. ctx binaries are copied once per build to `~/.cache/ctx-bench/<sha>/`.
2. A seatbelt profile (`results/runs/<exp>/<run>/sandbox.sb`) that denies the real home folder (no source code, notes, configs, memories), the rest of `/tmp` (other runs), the keychain (`/usr/bin/security`; agy's keyring library otherwise pops up dialogs) and network or automounted volumes (`/Volumes`, `/home`, `/net`: an agent that searches `/` would otherwise make macOS ask you to let ctx-launch "access files on a network volume"). Network is open.
3. One sandboxed driver script starts everything, so it all shares one sandbox: the private ctx server (`CTX_HOME` in the run folder), the setup's installers run the way a user runs them (`ctx install hooks for antigravity`, `agy plugin install <plugin>`, `ctx install hooks for claude`, `--plugin-dir`), the task's `setup.sh`, then the agent with the task prompt, under a timeout.
4. After the agent exits, the task's `check.sh` runs (the agent's servers are still up), then every process using the run folder is killed and the folder removed (`--keep` keeps it). The transcript, the agent's final message, the ctx activity log and the final working folder are kept in `results/runs/<experiment>/<run>/`.

The agent never sees bench's code, the check scripts or the ctx source; it sees the ctx binary, the integration files ctx installs and the skills, as a user's agent would.

## Layout

- `bench`: CLI. `benchlib/`: `runner.py` (schedule, run, record), `sandbox.py` (run folder, seatbelt profile), `agents.py` (one adapter per agent), `report.py`, `schema.sql`, `db.py`.
- `experiments/*.toml`: a spec: agents and models, setups, tasks (or `"all"`), reps, jobs, timeout, seed, hypothesis.
- `tasks/<name>/`: `task.md` (prompt; `{{port}}` becomes a free port), `setup.sh` (builds the working folder), `check.sh` (exit 0 = pass; may print a JSON line with `score` for partial credit; gets `BENCH_PORT` and `BENCH_RESPONSE`, the agent's final message), `solve.sh` (reference solution, used by the oracle), `task.toml` (`workdir`, `description`, optional `timeout`, optional `needs = ["ctx"]` for tasks that only make sense with ctx).
- `results/` (git-ignored): `bench.sqlite`, `runs/`, `reports/`.

## Setups (in ctx-skills.toml)

- `plain`: the agent's own shell, nothing installed. The baseline.
- `ctx`: ctx installed as the user would (`ctx install hooks for <agent>`), so shell calls run in ctx tabs.
- `ctx-skills`: ctx plus the `ctx/integrations/ctx-skills` plugin.

A setup is a table of components (`ctx = true`, `plugins = [...]`); each agent adapter knows how to install them, so a new setup is usually only a new table.

## What's measured

Per run (`outcomes`): `passed`, `score`, `wall_seconds` (agent start to exit, measured by the driver), `total_seconds` (with setup and check), `timed_out`, `agent_exit_code`, `agent_seconds` (agent's own figure), `turns`, `tokens` (`input`, `output`, `thinking`, `cache_read`, `cache_write`, `total`), `cost_usd` (Claude), `tool_calls` by tool, `shell_calls`, `shell_calls_writing_ctx` (commands where the agent wrote `ctx` itself), `skill_reads` (tool calls that touched a skill's folder), `ctx` (sentences by verb, hook-issued vs from a shell, CLI failures and misuse), `check_output`, `leftover_processes`, `invalid_reasons`, install output.

Per run (`env`): agent version, ctx version, binary hash, binary mtime and git state, plugin and task content hashes. Per experiment (`env`): host, OS and build, CPU, memory, Python, SQLite, harness version and git state. `vars`: agent, model, setup and its components, task, rep, the exact prompt and its hash, port, skills, concurrency, sandbox, permission mode, timeout.

A run is **invalid** (excluded from the report, listed at its end) when the setup didn't take effect, e.g. a ctx setup where no shell command went through ctx. This caught a real bug while building the harness: when ctx couldn't open a tab, the hook quietly fell back to the agent's own shell. An **infra_error** (quota, auth, overload, no result) says nothing about the setup, even when it hits mid-run, so it isn't scored. The run queue pauses every worker when one happens (until the quota's reset time when the agent reports it, e.g. agy's "Resets in 1h17m", else 5 minutes) and retries the cell, up to 6 times; `--resume` retries what is left. An overnight run waits out quota windows on its own.

The report gives, per agent and model: pass rate, mean score, median wall time and tokens per setup; each setup against the baseline and against the previous setup as a geometric mean over tasks of the ratio of medians, with a 95% bootstrap CI that resamples runs within each task; and a per-task table. Order is shuffled with a recorded seed so time-of-day and quota effects spread across setups.

## Adding things

- A task: a folder under `tasks/` with the five files; check that the oracle passes it (`--agent oracle --task <name>`) and that `check.sh` fails before `solve.sh`.
- An experiment: a new TOML in `experiments/`. Results of different specs never mix; each `bench run` is a new experiment row unless `--resume`.
- An agent: a class in `agents.py` with `version`, `prepare` (credentials, PATH), `install_commands`, `command`, `parse` (transcript to the outcome fields above) and `infra_error`, registered in `AGENTS`.
- An outcome: add it to the adapter's `parse` (then `bench reparse` applies it to old runs) or the runner; it lands in the `outcomes` JSON, and `json_extract` reaches it in SQL. Generated columns in `schema.sql` (`passed`, `score`, `wall_seconds`, `total_tokens`, `valid`) cover the common ones.

## Known limits

- Runs share the machine (`jobs` > 1), so wall time includes some contention; `vars.jobs` records it.
- The agents run with permissions skipped (`--dangerously-skip-permissions`, `bypassPermissions`) inside the sandbox, not in auto mode.
- `/tmp` outside the run folder is denied, so an agent that writes to `/tmp/foo` gets an error in every setup alike.
- `skill_reads` detects a skill by its folder name in tool-call arguments; agy reads `SKILL.md` with `read_file`, Claude uses the `Skill` tool.

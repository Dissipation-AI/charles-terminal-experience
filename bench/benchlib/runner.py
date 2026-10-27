"""Runs one experiment: expands the spec into cells, runs each cell in its own sandbox, and records
every run in the database."""
import hashlib
import json
import os
import platform
import random
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import tomllib
import traceback
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .agents import AGENTS, quota_reset_seconds
from .db import DB, now
from .sandbox import LINUX, RunDir

BENCH = Path(__file__).resolve().parent.parent
REPO = BENCH.parent
TASKS = BENCH / "tasks"
RESULTS = BENCH / "results"
HARNESS_VERSION = 1

print_lock = threading.Lock()


def log(msg: str):
    with print_lock:
        print(msg, flush=True)


# ---------------------------------------------------------------- provenance


def sha_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def sha_tree(p: Path) -> str:
    h = hashlib.sha256()
    for f in sorted(x for x in p.rglob("*") if x.is_file()):
        h.update(str(f.relative_to(p)).encode() + b"\0" + f.read_bytes() + b"\0")
    return h.hexdigest()


def git(path: Path, *args) -> str:
    r = subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True)
    return r.stdout.strip()


def git_state(path: Path) -> dict:
    return {"commit": git(path, "rev-parse", "HEAD"), "branch": git(path, "rev-parse", "--abbrev-ref", "HEAD"),
            "dirty": bool(git(path, "status", "--porcelain"))}


def host_env() -> dict:
    sh = lambda *a: subprocess.run(a, capture_output=True, text=True).stdout.strip()
    return {
        "host": platform.node(),
        "os": f"macOS {platform.mac_ver()[0]}",
        "os_build": sh("sw_vers", "-buildVersion"),
        "cpu": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "cores": os.cpu_count(),
        "memory_gb": round(int(sh("sysctl", "-n", "hw.memsize") or 0) / 2**30),
        "python": sys.version.split()[0],
        "sqlite": __import__("sqlite3").sqlite_version,
        "harness_version": HARNESS_VERSION,
        "harness_git": git_state(REPO),
    }


# ---------------------------------------------------------------- spec


def load_spec(path: Path) -> dict:
    spec = tomllib.loads(path.read_text())
    spec.setdefault("reps", 1)
    spec.setdefault("jobs", 1)
    spec.setdefault("timeout", 900)
    spec.setdefault("seed", 0)
    if spec.get("tasks", "all") == "all":
        spec["tasks"] = sorted(p.name for p in TASKS.iterdir() if (p / "task.md").exists())
    for name, setup in spec["setups"].items():
        setup.setdefault("ctx", False)
        setup.setdefault("plugins", [])
    return spec


def task_info(name: str) -> dict:
    d = TASKS / name
    meta = tomllib.loads((d / "task.toml").read_text()) if (d / "task.toml").exists() else {}
    meta.setdefault("workdir", "project")
    meta["dir"] = d
    meta["prompt_template"] = (d / "task.md").read_text().strip()
    return meta


def render(template: str, values: dict) -> str:
    return re.sub(r"\{\{(\w+)\}\}", lambda m: str(values[m.group(1)]), template)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def plugin_skills(plugin: Path) -> list[str]:
    d = plugin / "skills"
    return sorted(p.name for p in d.iterdir() if (p / "SKILL.md").exists()) if d.exists() else []


# ---------------------------------------------------------------- ctx inside a run

CTX_SHIM = """#!/bin/sh
# Records each ctx call the agent (or a hook) makes, then runs the real ctx.
err=$(mktemp)
"{real}" "$@" 2>"$err"; st=$?
cat "$err" >&2
printf '%s\\t%s\\t%s\\n' "$st" "$*" "$(head -c 300 "$err" | tr '\\n\\t' '  ')" >> "{log}"
rm -f "$err"
exit $st
"""

CTX_MISUSE = re.compile(r"isn't a ctx verb|Did you mean|Put it in quotes|isn't a valid ctx|There's no tab named")


CTX_BINS = Path.home() / ".cache/ctx-bench"


def install_ctx(rd: RunDir, ctx_bin: Path):
    # One copy per build, at a path that stays the same across runs: a rebuild mid-experiment
    # doesn't change what runs, and macOS sees one program rather than a new one each run (it
    # asks about privacy permissions per program).
    real = CTX_BINS / sha_file(ctx_bin / "ctx")[:16]
    if not (real / "ctx").exists():
        tmp = real.with_suffix(f".tmp{os.getpid()}-{threading.get_ident()}")  # runs fill it at once
        shutil.rmtree(tmp, ignore_errors=True)
        tmp.mkdir(parents=True)
        for exe in ("ctx", "ctx-launch", "ctx-helper"):
            if (ctx_bin / exe).exists():
                shutil.copy2(ctx_bin / exe, tmp / exe)
        try:
            tmp.rename(real)
        except OSError:
            shutil.rmtree(tmp, ignore_errors=True)  # another run got there first
    for exe in real.iterdir():
        rd.readable.append(exe)
    rd.ctx_home.mkdir()
    shim = rd.bin / "ctx"
    shim.write_text(CTX_SHIM.format(real=real / "ctx", log=rd.private / "ctx-calls.log"))
    shim.chmod(0o755)
    return real / "ctx"


def ctx_metrics(rd: RunDir, activity_offset: int, calls_offset: int) -> dict:
    activity = rd.ctx_home / "data/activity.log"
    entries = []
    if activity.exists():
        for line in activity.read_text(errors="replace").splitlines()[activity_offset:]:
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    verbs = {}
    for e in entries:
        words = (e.get("sentence") or "").split()
        verb = words[1] if len(words) > 1 else "?"
        verbs[verb] = verbs.get(verb, 0) + 1
    calls = []
    log_path = rd.private / "ctx-calls.log"
    if log_path.exists():
        calls = log_path.read_text(errors="replace").splitlines()[calls_offset:]
    failed = [c for c in calls if not c.startswith("0\t")]
    return {
        "sentences": len(entries),
        "by_verb": verbs,
        "via_hook": sum("through its hook" in (e.get("client") or "") for e in entries),
        "direct": sum("through its hook" not in (e.get("client") or "") for e in entries),
        "runs": verbs.get("run", 0),
        "cli_calls": len(calls),
        "cli_failed": len(failed),
        "cli_misuse": sum(bool(CTX_MISUSE.search(c)) for c in calls),
        "failed_examples": failed[:10],
    }


def ctx_line_count(path: Path) -> int:
    return len(path.read_text(errors="replace").splitlines()) if path.exists() else 0


# ---------------------------------------------------------------- one run


class Runner:
    def __init__(self, db: DB, spec: dict, spec_path: Path, experiment_id: str, keep: bool = False):
        self.db, self.spec, self.spec_path, self.exp, self.keep = db, spec, spec_path, experiment_id, keep
        ctx_cfg = spec.get("ctx", {})
        self.ctx_bin = (REPO / ctx_cfg.get("bin", "ctx/target/release")).resolve()
        self.ctx_repo = (REPO / ctx_cfg.get("repo", "ctx")).resolve()
        self.ctx_env = None
        if any(s["ctx"] for s in spec["setups"].values()):
            ctx = self.ctx_bin / "ctx"
            if not ctx.exists():
                raise SystemExit(f"ctx isn't built at {ctx}: cargo build --release in {self.ctx_repo}")
            self.ctx_env = {
                "ctx_version": subprocess.run([ctx, "--version"], capture_output=True, text=True).stdout.strip(),
                "ctx_bin_sha": sha_file(ctx),
                "ctx_bin_mtime": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ctx.stat().st_mtime)),
                "ctx_git": git_state(self.ctx_repo),
            }
        self.agent_versions = {}

    def agent_version(self, agent):
        if agent.name not in self.agent_versions:
            self.agent_versions[agent.name] = agent.version()
        return self.agent_versions[agent.name]

    def run_cell(self, cell: tuple, order_index: int):
        agent_name, model, setup_name, task_name, rep = cell
        agent = AGENTS[agent_name]
        setup = self.spec["setups"][setup_name]
        task = task_info(task_name)
        timeout = int(task.get("timeout", self.spec["timeout"]))
        run_id = str(uuid.uuid4())
        art = RESULTS / "runs" / self.exp / run_id
        art.mkdir(parents=True)
        plugins = [(REPO / p).resolve() for p in setup["plugins"]]
        skills = sorted({s for p in plugins for s in plugin_skills(p)})
        port = free_port()
        prompt = render(task["prompt_template"], {"port": port})
        vars_ = {
            "agent": agent_name, "model": model, "setup": setup_name, "setup_spec": setup, "task": task_name,
            "rep": rep, "timeout": timeout, "prompt": prompt,
            "prompt_sha": hashlib.sha256(prompt.encode()).hexdigest(), "port": port, "skills": skills,
            "jobs": self.spec["jobs"], "sandbox": "bwrap" if LINUX else "seatbelt", "permission_mode": "skip-all",
        }
        env_ = {
            "agent_version": self.agent_version(agent),
            "task_sha": sha_tree(task["dir"]),
            "plugins": {str(p.relative_to(REPO)): sha_tree(p) for p in plugins},
            **({"ctx": self.ctx_env} if setup["ctx"] else {}),
        }
        self.db.insert_run({
            "id": run_id, "experiment_id": self.exp, "agent": agent_name, "model": model, "setup": setup_name,
            "task": task_name, "rep": rep, "attempt": self.db.attempts(self.exp, cell) + 1,
            "order_index": order_index, "status": "running", "queued_at": now(), "started_at": now(),
            "vars": vars_, "env": env_, "artifacts_dir": str(art.relative_to(BENCH)),
        })
        rd = RunDir.create(task["workdir"])
        outcomes = {"invalid_reasons": []}
        status, error = "done", None
        t_start = time.monotonic()
        proc = None
        try:
            extra = agent.prepare(rd)
            extra.update({"BENCH_PORT": str(port)})
            real_ctx = None
            if setup["ctx"]:
                real_ctx = install_ctx(rd, self.ctx_bin)
                extra.update({"CTX_HOME": str(rd.ctx_home), "CTX_ASSIST": "off"})
            env = rd.env(extra)
            plugin_copies = []
            for p in plugins:
                dest = rd.private / "plugins" / p.name
                shutil.copytree(p, dest, symlinks=False)
                plugin_copies.append(str(dest))
            rd.write_profile()
            (art / "sandbox.sb").write_text(rd.profile_path.read_text())

            # Everything in the run (ctx server, installers, task setup, agent) starts from one
            # sandboxed driver, so they share one sandbox, as they would share a login on a real
            # machine. (ctx won't open tabs for a process in a sandbox other than its own.)
            installs = agent.install_commands(rd, {**setup, "plugins": plugin_copies})
            argv = agent.command(prompt, model, timeout, {**setup, "plugins": plugin_copies}, task)
            driver = write_driver(rd, real_ctx, installs, task["dir"] / "setup.sh", argv, timeout)
            with open(art / "driver.log", "w") as dlog:
                proc = rd.popen(["/bin/zsh", str(driver)], env=env, cwd=rd.work, stdout=dlog,
                                stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    proc.wait(timeout=timeout + 600)
                    timed_out = False
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                    timed_out = True
            run = rd.private / "run"
            for f in ("transcript.jsonl", "agent.stderr", "install.log", "setup.log", "ctx-server.log"):
                if (run / f).exists():
                    shutil.copy2(run / f, art / f)
            steps = dict(l.split() for l in (run / "steps").read_text().splitlines()) if (run / "steps").exists() else {}
            fail = {91: "ctx server didn't start", 92: "install failed", 93: "task setup failed"}.get(proc.returncode)
            if fail:
                detail = (art / "install.log").read_text()[-800:] if proc.returncode == 92 else \
                    (art / "setup.log").read_text()[-800:] if proc.returncode == 93 else (art / "driver.log").read_text()[-800:]
                raise RuntimeError(f"{fail}: {detail}")
            outcomes["install"] = (art / "install.log").read_text()[-3000:] if (art / "install.log").exists() else ""
            if "agent_start" not in steps:
                raise RuntimeError("the agent never started: " + (art / "driver.log").read_text()[-800:])
            timed_out = timed_out or "agent_end" not in steps or "agent_timeout" in steps
            wall = float(steps.get("agent_end", time.time())) - float(steps["agent_start"])
            self.db.update_run(run_id, agent_started_at=iso(float(steps["agent_start"])),
                               agent_ended_at=iso(float(steps["agent_end"])) if "agent_end" in steps else None)
            rc = int((run / "agent.rc").read_text()) if (run / "agent.rc").exists() else None
            transcript = art / "transcript.jsonl"
            stderr_path = art / "agent.stderr"
            transcript.touch(); stderr_path.touch()
            parsed = agent.parse(transcript, skills)
            (art / "response.md").write_text(parsed.get("response") or "")
            outcomes.update(parsed)
            outcomes.update({"wall_seconds": round(wall, 3), "timed_out": timed_out, "agent_exit_code": rc})
            act_off = int(steps.get("ctx_activity_offset", 0))
            calls_off = int(steps.get("ctx_calls_offset", 0))

            check_env = {**env, "BENCH_RESPONSE": str(art / "response.md")}
            c = subprocess.run(["sh", str(task["dir"] / "check.sh")], cwd=rd.work, env=check_env,
                               capture_output=True, text=True, timeout=180)
            outcomes["passed"] = c.returncode == 0
            outcomes["check_output"] = (c.stdout + c.stderr)[-3000:]
            score = None
            for line in reversed(c.stdout.strip().splitlines()):
                try:
                    detail = json.loads(line)
                    score, outcomes["check_detail"] = detail.get("score"), detail
                    break
                except (json.JSONDecodeError, AttributeError):
                    continue
            outcomes["score"] = float(score) if score is not None else float(outcomes["passed"])

            if setup["ctx"]:
                outcomes["ctx"] = ctx_metrics(rd, act_off, calls_off)
                shutil.copy2(rd.ctx_home / "data/activity.log", art / "ctx-activity.log") if (
                    rd.ctx_home / "data/activity.log").exists() else None
                if outcomes["shell_calls"] and not outcomes["ctx"]["runs"]:
                    outcomes["invalid_reasons"].append("ctx setup, but no shell command went through ctx")
            if skills and agent_name == "claude" and not any(
                    s.startswith(tuple(f"{p.name}:" for p in plugins)) for s in outcomes.get("skills_available") or []):
                outcomes["invalid_reasons"].append("skills setup, but Claude didn't list the plugin's skills")
            infra = agent.infra_error(parsed, stderr_path.read_text(errors="replace")[-5000:])
            if infra and not outcomes["passed"]:
                status, error = "infra_error", f"agent infrastructure: {infra}"
                reset = quota_reset_seconds(stderr_path.read_text(errors="replace")[-5000:] + str(parsed.get("agent_error")))
                outcomes["quota_reset_seconds"] = reset
            if parsed.get("agent_status") is None and not timed_out:
                status, error = "infra_error", "agent produced no result: " + stderr_path.read_text(errors="replace")[-500:]
            snapshot(rd.work, art / "work")
        except Exception as e:
            status, error = "harness_error", f"{e}\n{traceback.format_exc()[-2000:]}"
        finally:
            outcomes["leftover_processes"] = rd.kill_leftovers()
            # The ctx binary lives outside the run folder, so its server isn't found by path.
            pid_file = rd.private / "run/ctx-server.pid"
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), signal.SIGKILL)
                except (ProcessLookupError, ValueError):
                    pass
            subprocess.run(["pkill", "-9", "-f", str(rd.root)], capture_output=True)
            kill_port(port)
            if not self.keep:
                rd.remove()
        outcomes["total_seconds"] = round(time.monotonic() - t_start, 3)
        self.db.update_run(run_id, status=status, error=error, outcomes=outcomes, ended_at=now())
        tok = outcomes.get("tokens", {}).get("total")
        log(f"[{order_index:3}] {agent_name}/{model} {setup_name:12} {task_name:22} rep {rep}: "
            f"{status}{' PASS' if outcomes.get('passed') else ' FAIL' if status == 'done' else ''} "
            f"{outcomes.get('wall_seconds', 0):.0f}s tokens={tok} "
            f"{'INVALID: ' + '; '.join(outcomes['invalid_reasons']) if outcomes['invalid_reasons'] else ''}"
            f"{(error or '').splitlines()[0][:200] if error else ''}")
        return status, outcomes.get("quota_reset_seconds")


DRIVER = """zmodload zsh/datetime
run={run}
mkdir -p $run
step() {{ print -r -- "$1 ${{2:-$EPOCHREALTIME}}" >> $run/steps }}
lines() {{ [[ -f $1 ]] && wc -l < $1 | tr -d ' ' || print 0 }}
{ctx_start}
: > $run/install.log
{installs}
sh $run/setup.sh > $run/setup.log 2>&1 || exit 93
rm -f $run/setup.sh
{offsets}
step agent_start
{agent} > $run/transcript.jsonl 2> $run/agent.stderr < /dev/null &
apid=$!
( sleep {timeout}; step agent_timeout; kill -TERM $apid; sleep 10; kill -KILL $apid ) 2>/dev/null &
wpid=$!
wait $apid
print $? > $run/agent.rc
step agent_end
kill $wpid 2>/dev/null
"""

CTX_START = """{ctx} server > $run/ctx-server.log 2>&1 &
print $! > $run/ctx-server.pid
for i in {{1..100}}; do {ctx} status > /dev/null 2>&1 && break; sleep 0.1; done
{ctx} status > /dev/null 2>&1 || exit 91"""


def write_driver(rd: RunDir, real_ctx, installs, setup_sh: Path, agent_argv, timeout: int) -> Path:
    run = rd.private / "run"
    run.mkdir()
    shutil.copy2(setup_sh, run / "setup.sh")  # removed again before the agent starts
    q = lambda argv: " ".join(shlex.quote(str(a)) for a in argv)
    inst = "\n".join(
        f"print -r -- '$ '{shlex.quote(q(a))} >> $run/install.log; "
        f"(cd {shlex.quote(str(rd.root))} && {q(a)}) >> $run/install.log 2>&1 || exit 92" for a in installs)
    offsets = ""
    if real_ctx:
        offsets = (f"step ctx_activity_offset $(lines {shlex.quote(str(rd.ctx_home / 'data/activity.log'))})\n"
                   f"step ctx_calls_offset $(lines {shlex.quote(str(rd.private / 'ctx-calls.log'))})")
    text = DRIVER.format(run=shlex.quote(str(run)), installs=inst, timeout=timeout, offsets=offsets, agent=q(agent_argv),
                         ctx_start=CTX_START.format(ctx=shlex.quote(str(real_ctx))) if real_ctx else "")
    path = run / "driver.zsh"
    path.write_text(text)
    return path


def iso(epoch: float) -> str:
    from datetime import datetime, timezone
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat(timespec="milliseconds")


def kill_port(port: int):
    out = subprocess.run(["lsof", "-t", f"-iTCP:{port}", "-sTCP:LISTEN"], capture_output=True, text=True).stdout
    for pid in out.split():
        try:
            os.kill(int(pid), 9)
        except (ProcessLookupError, ValueError):
            pass


def snapshot(src: Path, dest: Path, limit=20 * 2**20):
    """Keep the final working folder for review, skipping anything large."""
    def ignore(d, names):
        # Large files, and sockets or other special files a task's daemon leaves behind.
        return [n for n in names if not (Path(d) / n).is_dir() and not (Path(d) / n).is_symlink() and (
            not (Path(d) / n).is_file() or (Path(d) / n).stat().st_size > limit)]
    shutil.copytree(src, dest, symlinks=True, ignore=ignore, dirs_exist_ok=True)


# ---------------------------------------------------------------- experiment


def run_experiment(spec_path: Path, filters: dict, resume: str | None, keep: bool, dry_run: bool):
    spec = load_spec(spec_path)
    for k in ("reps", "jobs"):
        if filters.get(k):
            spec[k] = filters[k]
    db = DB(RESULTS / "bench.sqlite")
    if resume:
        row = db.experiment(resume)
        if not row:
            raise SystemExit(f"no experiment {resume}")
        exp_id = row["id"]
    else:
        exp_id = f"{time.strftime('%Y-%m-%d')}-{spec['name']}-{uuid.uuid4().hex[:4]}"

    pick = lambda key, values: [v for v in values if not filters.get(key) or v in filters[key]]
    cells = [
        (agent, model, setup, task, rep)
        for agent in pick("agent", list(spec["agents"]))
        for model in pick("model", spec["agents"][agent]["models"])
        for setup in pick("setup", list(spec["setups"]))
        for task in pick("task", spec["tasks"])
        for rep in range(1, spec["reps"] + 1)
        # A task.toml's `needs = ["ctx"]` keeps it to setups that have ctx.
        if all(spec["setups"][setup].get(n) for n in task_info(task).get("needs", []))
    ]
    done = db.finished_cells(exp_id) if resume else set()
    todo = [c for c in cells if c not in done]
    random.Random(f"{spec['seed']}-{exp_id}").shuffle(todo)
    log(f"experiment {exp_id}: {len(todo)} runs to do ({len(cells) - len(todo)} already done), "
        f"{spec['jobs']} at a time")
    if dry_run:
        for c in todo:
            log("  " + " ".join(map(str, c)))
        return exp_id
    if not resume:
        db.create_experiment(exp_id, spec["name"], spec_path.relative_to(REPO) if spec_path.is_relative_to(REPO)
                             else spec_path, sha_file(spec_path), spec, spec.get("hypothesis"), host_env())
    runner = Runner(db, spec, spec_path, exp_id, keep)
    run_queue(runner, todo, spec["jobs"])
    return exp_id


INFRA_RETRIES = 6       # per cell, then it stays an infra_error for --resume
INFRA_PAUSE = 300       # seconds, when the error doesn't say when a quota resets


def run_queue(runner, todo: list, jobs: int):
    """Run cells `jobs` at a time. An infra error (quota, overload, auth) pauses every worker,
    until the quota's reset time when the agent says it, then the cell goes back in the queue.
    So an overnight run waits out a quota instead of burning through the queue."""
    import queue
    q = queue.Queue()
    for i, c in enumerate(todo):
        q.put((i, c, 0))
    state = {"pause_until": 0.0}
    lock = threading.Lock()

    def worker():
        while True:
            try:
                i, cell, tries = q.get_nowait()
            except queue.Empty:
                return
            while (wait := state["pause_until"] - time.time()) > 0:
                time.sleep(min(wait, 30))
            status, reset = runner.run_cell(cell, i)
            if status == "infra_error" and tries + 1 < INFRA_RETRIES:
                with lock:
                    until = time.time() + (reset + 60 if reset else INFRA_PAUSE)
                    if until > state["pause_until"]:
                        state["pause_until"] = until
                        log(f"pausing all runs until {time.strftime('%H:%M', time.localtime(until))} "
                            f"({'quota resets' if reset else 'infra error'}); then retrying")
                q.put((i, cell, tries + 1))

    threads = [threading.Thread(target=worker) for _ in range(jobs)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

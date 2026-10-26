"""Summaries of an experiment: per setup and per task, plus paired comparisons against a baseline
setup with bootstrap confidence intervals."""
import json
import math
import random
import statistics
from collections import defaultdict

from .db import DB


def _runs(db: DB, exp_id: str, filters: dict) -> list[dict]:
    rows = db.query("SELECT * FROM runs WHERE experiment_id = ? AND status = 'done'", (exp_id,))
    out = []
    for r in rows:
        d = dict(r)
        d["outcomes"] = json.loads(d["outcomes"])
        d["vars"] = json.loads(d["vars"])
        if all(not v or d[k] in v for k, v in filters.items() if k in ("agent", "model", "setup", "task")):
            out.append(d)
    return out


def _med(xs):
    return statistics.median(xs) if xs else float("nan")


def _geo_ratio_ci(pairs: dict, n_boot=4000, seed=0):
    """Geometric mean over tasks of median(setup)/median(baseline), with a bootstrap CI that
    resamples runs within each task (so tasks are weighted equally)."""
    rng = random.Random(seed)
    tasks = [t for t, (a, b) in pairs.items() if a and b and all(x > 0 for x in a + b)]
    if not tasks:
        return None
    point = math.exp(statistics.mean(math.log(_med(pairs[t][0]) / _med(pairs[t][1])) for t in tasks))
    boots = []
    for _ in range(n_boot):
        logs = []
        for t in tasks:
            a, b = pairs[t]
            ra = [rng.choice(a) for _ in a]
            rb = [rng.choice(b) for _ in b]
            logs.append(math.log(_med(ra) / _med(rb)))
        boots.append(math.exp(statistics.mean(logs)))
    boots.sort()
    return point, boots[int(0.025 * n_boot)], boots[int(0.975 * n_boot) - 1], len(tasks)


def _fmt_ratio(r):
    if not r:
        return "n/a"
    p, lo, hi, n = r
    return f"{p:.2f}x [{lo:.2f}, {hi:.2f}]"


def report(db: DB, exp_id: str, baseline: str | None = None, filters: dict | None = None) -> str:
    exp = db.experiment(exp_id)
    if not exp:
        raise SystemExit(f"no experiment {exp_id}")
    exp_id = exp["id"]
    spec = json.loads(exp["spec"])
    runs = _runs(db, exp_id, filters or {})
    invalid = [r for r in runs if r["outcomes"].get("invalid_reasons")]
    valid = [r for r in runs if not r["outcomes"].get("invalid_reasons")]
    counts = {row[0]: row[1] for row in db.query(
        "SELECT status, COUNT(*) FROM runs WHERE experiment_id = ? GROUP BY status", (exp_id,))}
    setups = list(spec["setups"])
    baseline = baseline or setups[0]
    lines = [f"# {exp['name']} ({exp_id})", ""]
    if exp["hypothesis"]:
        lines += [exp["hypothesis"].strip(), ""]
    lines += [f"Runs by status: {counts}. Valid finished runs: {len(valid)}; invalid (excluded): {len(invalid)}.", ""]

    groups = defaultdict(list)
    for r in valid:
        groups[(r["agent"], r["model"])].append(r)
    for (agent, model), rs in sorted(groups.items()):
        lines += [f"## {agent} / {model}", ""]
        lines += ["| setup | runs | pass rate | mean score | median wall s | median tokens | median output+thinking | median tool calls | skill loaded | ctx misuse |",
                  "|---|---|---|---|---|---|---|---|---|---|"]
        by_setup = defaultdict(list)
        for r in rs:
            by_setup[r["setup"]].append(r)
        for s in setups:
            xs = by_setup.get(s, [])
            if not xs:
                continue
            o = [x["outcomes"] for x in xs]
            skill = sum(bool(x.get("skill_reads")) for x in o)
            misuse = sum((x.get("ctx") or {}).get("cli_misuse", 0) for x in o)
            lines.append(
                f"| {s} | {len(xs)} | {sum(x['passed'] for x in o) / len(o):.0%} | "
                f"{statistics.mean(x['score'] for x in o):.2f} | {_med([x['wall_seconds'] for x in o]):.0f} | "
                f"{_med([x['tokens']['total'] for x in o]):,.0f} | "
                f"{_med([x['tokens']['output'] + x['tokens']['thinking'] for x in o]):,.0f} | "
                f"{_med([x['tool_calls_total'] for x in o]):.0f} | "
                f"{skill}/{len(o) if xs[0]['vars']['skills'] else 0} | {misuse} |")
        lines.append("")

        # Paired comparisons: each setup against the baseline, task by task.
        lines += [f"Compared with `{baseline}` (geometric mean over tasks of the ratio of medians; "
                  "95% bootstrap CI; below 1 is better):", "",
                  "| setup | wall time | total tokens | output+thinking tokens | pass rate change |",
                  "|---|---|---|---|---|"]
        cmp_pairs = [(s, baseline) for s in setups if s != baseline]
        # Also each setup against the one before it (e.g. ctx+skills vs ctx).
        cmp_pairs += [(setups[i], setups[i - 1]) for i in range(2, len(setups))]
        for s, b in cmp_pairs:
            def pairs(metric):
                d = {}
                for t in {r["task"] for r in rs}:
                    a = [metric(r["outcomes"]) for r in by_setup.get(s, []) if r["task"] == t]
                    c = [metric(r["outcomes"]) for r in by_setup.get(b, []) if r["task"] == t]
                    d[t] = (a, c)
                return d
            pa = [r["outcomes"]["passed"] for r in by_setup.get(s, [])]
            pb = [r["outcomes"]["passed"] for r in by_setup.get(b, [])]
            dp = (sum(pa) / len(pa) - sum(pb) / len(pb)) * 100 if pa and pb else float("nan")
            lines.append(
                f"| {s} vs {b} | {_fmt_ratio(_geo_ratio_ci(pairs(lambda o: o['wall_seconds'])))} | "
                f"{_fmt_ratio(_geo_ratio_ci(pairs(lambda o: o['tokens']['total'])))} | "
                f"{_fmt_ratio(_geo_ratio_ci(pairs(lambda o: o['tokens']['output'] + o['tokens']['thinking'])))} | "
                f"{dp:+.0f} pts |")
        lines.append("")

        lines += ["Per task (pass count / runs, median wall s, median tokens in thousands):", "",
                  "| task | " + " | ".join(setups) + " |", "|---|" + "---|" * len(setups)]
        for t in sorted({r["task"] for r in rs}):
            cells = []
            for s in setups:
                o = [r["outcomes"] for r in by_setup.get(s, []) if r["task"] == t]
                cells.append(f"{sum(x['passed'] for x in o)}/{len(o)}, {_med([x['wall_seconds'] for x in o]):.0f}s, "
                             f"{_med([x['tokens']['total'] for x in o]) / 1000:.0f}k" if o else "-")
            lines.append(f"| {t} | " + " | ".join(cells) + " |")
        lines.append("")

    if invalid:
        lines += ["## Invalid runs (excluded above)", ""]
        for r in invalid:
            lines.append(f"- `{r['id']}` {r['agent']}/{r['setup']}/{r['task']} rep {r['rep']}: "
                         + "; ".join(r["outcomes"]["invalid_reasons"]))
        lines.append("")
    errs = db.query("SELECT id, agent, setup, task, rep, status, substr(error, 1, 160) AS e FROM runs "
                    "WHERE experiment_id = ? AND status != 'done'", (exp_id,))
    if errs:
        lines += ["## Runs that didn't finish", ""]
        for r in errs:
            lines.append(f"- `{r['id']}` {r['agent']}/{r['setup']}/{r['task']} rep {r['rep']}: {r['status']}: "
                         + (r["e"] or "").replace("\n", " "))
        lines.append("")
    return "\n".join(lines)

"""The results database: every experiment and every run, in results/bench.sqlite."""
import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = (Path(__file__).parent / "schema.sql").read_text()


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class DB:
    """A connection shared by the worker threads; writes are serialised by a lock."""

    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.executescript(SCHEMA)
        self.lock = threading.Lock()

    def execute(self, sql: str, args=()):
        with self.lock:
            return self.conn.execute(sql, args)

    def query(self, sql: str, args=()) -> list[sqlite3.Row]:
        with self.lock:
            return self.conn.execute(sql, args).fetchall()

    def create_experiment(self, id, name, spec_path, spec_sha, spec, hypothesis, env):
        self.execute(
            "INSERT INTO experiments (id, name, created_at, spec_path, spec_sha, spec, hypothesis, env)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (id, name, now(), str(spec_path), spec_sha, json.dumps(spec), hypothesis, json.dumps(env)),
        )

    def experiment(self, id_or_name: str):
        rows = self.query(
            "SELECT * FROM experiments WHERE id = ? OR name = ? ORDER BY created_at DESC", (id_or_name, id_or_name)
        )
        return rows[0] if rows else None

    def insert_run(self, run: dict):
        cols = ", ".join(run)
        marks = ", ".join("?" for _ in run)
        vals = [json.dumps(v) if isinstance(v, (dict, list)) else v for v in run.values()]
        self.execute(f"INSERT INTO runs ({cols}) VALUES ({marks})", vals)

    def update_run(self, id: str, **fields):
        sets = ", ".join(f"{k} = ?" for k in fields)
        vals = [json.dumps(v) if isinstance(v, (dict, list)) else v for v in fields.values()]
        self.execute(f"UPDATE runs SET {sets} WHERE id = ?", (*vals, id))

    def finished_cells(self, experiment_id: str) -> set[tuple]:
        """Cells with a usable result (an infra error is retried by a resumed run)."""
        rows = self.query(
            "SELECT agent, model, setup, task, rep FROM runs WHERE experiment_id = ? AND status = 'done'",
            (experiment_id,),
        )
        return {tuple(r) for r in rows}

    def attempts(self, experiment_id: str, cell: tuple) -> int:
        rows = self.query(
            "SELECT COUNT(*) FROM runs WHERE experiment_id = ? AND agent = ? AND model = ? AND setup = ?"
            " AND task = ? AND rep = ?",
            (experiment_id, *cell),
        )
        return rows[0][0]

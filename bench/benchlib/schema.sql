-- One row per experiment instance (each `bench run` of a spec, or a resumed one).
CREATE TABLE IF NOT EXISTS experiments (
  id          TEXT PRIMARY KEY,            -- e.g. 2026-10-25-ctx-skills-a1b2
  name        TEXT NOT NULL,               -- spec name, shared by every instance of the spec
  created_at  TEXT NOT NULL,               -- ISO 8601 UTC
  spec_path   TEXT NOT NULL,
  spec_sha    TEXT NOT NULL,               -- sha256 of the spec file as run
  spec        TEXT NOT NULL CHECK (json_valid(spec)),
  hypothesis  TEXT,
  env         TEXT NOT NULL CHECK (json_valid(env)),  -- host, OS, harness commit, ... at creation
  notes       TEXT
);

-- One row per agent session. vars = everything that went in, outcomes = everything measured,
-- env = versions and hashes that could explain a difference between two runs.
CREATE TABLE IF NOT EXISTS runs (
  id               TEXT PRIMARY KEY,         -- uuid4
  experiment_id    TEXT NOT NULL REFERENCES experiments(id),
  agent            TEXT NOT NULL,
  model            TEXT NOT NULL,
  setup            TEXT NOT NULL,
  task             TEXT NOT NULL,
  rep              INTEGER NOT NULL,
  attempt          INTEGER NOT NULL DEFAULT 1,   -- retries after infra errors get a new row
  order_index      INTEGER,                      -- position in the shuffled schedule
  status           TEXT NOT NULL,                -- running | done | infra_error | harness_error
  queued_at        TEXT NOT NULL,
  started_at       TEXT,
  agent_started_at TEXT,
  agent_ended_at   TEXT,
  ended_at         TEXT,
  vars             TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(vars)),
  env              TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(env)),
  outcomes         TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(outcomes)),
  error            TEXT,
  artifacts_dir    TEXT,
  -- Convenience columns for the outcomes every experiment has.
  passed       INTEGER GENERATED ALWAYS AS (json_extract(outcomes, '$.passed')) VIRTUAL,
  score        REAL    GENERATED ALWAYS AS (json_extract(outcomes, '$.score')) VIRTUAL,
  wall_seconds REAL    GENERATED ALWAYS AS (json_extract(outcomes, '$.wall_seconds')) VIRTUAL,
  total_tokens INTEGER GENERATED ALWAYS AS (json_extract(outcomes, '$.tokens.total')) VIRTUAL,
  valid        INTEGER GENERATED ALWAYS AS (json_array_length(outcomes, '$.invalid_reasons') = 0) VIRTUAL
);
CREATE INDEX IF NOT EXISTS runs_cell ON runs (experiment_id, agent, model, setup, task, rep);

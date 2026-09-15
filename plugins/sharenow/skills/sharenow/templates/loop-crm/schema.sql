CREATE TABLE leads (id TEXT PRIMARY KEY, email TEXT NOT NULL, name TEXT NOT NULL, company TEXT NOT NULL, status TEXT NOT NULL, score INTEGER, summary TEXT, attempts INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE INDEX leads_status ON leads (status);
CREATE TABLE loop_runs (id TEXT PRIMARY KEY, lead_id TEXT, source TEXT NOT NULL, status TEXT NOT NULL, detail TEXT, started_at TEXT NOT NULL, finished_at TEXT);
CREATE INDEX loop_runs_started ON loop_runs (started_at);
CREATE TABLE team_members (token_hash TEXT PRIMARY KEY, label TEXT NOT NULL, role TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE intake_rate_limits (key TEXT PRIMARY KEY, count INTEGER NOT NULL, updated_at TEXT NOT NULL);

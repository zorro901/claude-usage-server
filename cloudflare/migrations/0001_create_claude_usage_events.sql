CREATE TABLE IF NOT EXISTS claude_usage_events (
  id TEXT PRIMARY KEY,
  captured_at TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('current_session', 'transcript_summary')),
  host TEXT,
  host_label TEXT,
  platform TEXT,
  user_label TEXT,
  session_id TEXT,
  session_name TEXT,
  transcript_path TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cache_creation_input_tokens INTEGER,
  cache_read_input_tokens INTEGER,
  total_cost_usd REAL,
  payload_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_claude_usage_events_captured_at
  ON claude_usage_events(captured_at);

CREATE INDEX IF NOT EXISTS idx_claude_usage_events_kind
  ON claude_usage_events(kind);

CREATE INDEX IF NOT EXISTS idx_claude_usage_events_host_label
  ON claude_usage_events(host_label);

CREATE INDEX IF NOT EXISTS idx_claude_usage_events_session_id
  ON claude_usage_events(session_id);

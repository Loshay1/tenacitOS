#!/bin/bash
# sync-usage.sh — Collect OpenClaw token usage from sessions.json and write to usage-tracking.db
# Runs every 5 minutes via cron. Reads sessions.json from all agents,
# calculates costs using the same pricing as the dashboard, and inserts
# snapshots directly into the SQLite database.

set -euo pipefail

DB_PATH="/home/lmohsin/mission-control/data/usage-tracking.db"
AGENTS_DIR="/home/lmohsin/.openclaw/agents"

python3 << 'PYEOF'
import json, os, sys, time, sqlite3
from datetime import datetime, timezone

DB_PATH = "/home/lmohsin/mission-control/data/usage-tracking.db"
AGENTS_DIR = "/home/lmohsin/.openclaw/agents"

# Pricing table (USD per million tokens) — must match src/lib/pricing.ts
MODEL_PRICING = {
    "anthropic/claude-opus-4-6":    {"input": 15.00, "output": 75.00},
    "anthropic/claude-sonnet-4-5":  {"input":  3.00, "output": 15.00},
    "anthropic/claude-haiku-3-5":   {"input":  0.80, "output":  4.00},
    "anthropic/claude-haiku-4-5":   {"input":  0.80, "output":  4.00},
    "google/gemini-2.5-flash":      {"input":  0.15, "output":  0.60},
    "google/gemini-2.5-pro":        {"input":  1.25, "output":  5.00},
    "x-ai/grok-4-1-fast":           {"input":  2.00, "output": 10.00},
    "minimax/minimax-m2.5":         {"input":  0.30, "output":  1.10},
}

# Alias map — must match src/lib/pricing.ts normalizeModelId()
ALIAS_MAP = {
    "opus":             "anthropic/claude-opus-4-6",
    "sonnet":           "anthropic/claude-sonnet-4-5",
    "haiku":            "anthropic/claude-haiku-3-5",
    "gemini-flash":     "google/gemini-2.5-flash",
    "gemini-pro":       "google/gemini-2.5-pro",
    "claude-opus-4-6":  "anthropic/claude-opus-4-6",
    "claude-sonnet-4-5":"anthropic/claude-sonnet-4-5",
    "claude-haiku-3-5": "anthropic/claude-haiku-3-5",
    "claude-haiku-4-5": "anthropic/claude-haiku-4-5",
    "gemini-2.5-flash": "google/gemini-2.5-flash",
    "gemini-2.5-pro":   "google/gemini-2.5-pro",
    "minimax":          "minimax/minimax-m2.5",
    "minimax-m2.5":     "minimax/minimax-m2.5",
}

def normalize_model(model_id):
    return ALIAS_MAP.get(model_id, model_id)

def calculate_cost(model_id, input_tokens, output_tokens):
    normalized = normalize_model(model_id)
    pricing = MODEL_PRICING.get(normalized)
    if not pricing:
        # Default to Sonnet pricing
        pricing = {"input": 3.00, "output": 15.00}
    input_cost = (input_tokens / 1_000_000) * pricing["input"]
    output_cost = (output_tokens / 1_000_000) * pricing["output"]
    return input_cost + output_cost

def init_db(db_path):
    """Create the usage_snapshots table if it does not exist."""
    db_dir = os.path.dirname(db_path)
    os.makedirs(db_dir, exist_ok=True)

    conn = sqlite3.connect(db_path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS usage_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp INTEGER NOT NULL,
            date TEXT NOT NULL,
            hour INTEGER NOT NULL,
            agent_id TEXT NOT NULL,
            model TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            cost REAL NOT NULL,
            created_at INTEGER DEFAULT (strftime('%s', 'now'))
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_date ON usage_snapshots(date)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_agent ON usage_snapshots(agent_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_model ON usage_snapshots(model)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_timestamp ON usage_snapshots(timestamp)")
    conn.commit()
    return conn

def collect_sessions():
    """Read sessions.json from all agents, group by agent+model."""
    grouped = {}  # key: (agent_id, model) -> {inputTokens, outputTokens, totalTokens}

    for agent_name in sorted(os.listdir(AGENTS_DIR)):
        sessions_file = os.path.join(AGENTS_DIR, agent_name, "sessions", "sessions.json")
        if not os.path.isfile(sessions_file):
            continue

        try:
            with open(sessions_file) as f:
                sessions = json.load(f)
        except Exception as e:
            print(f"  WARN: Cannot read {sessions_file}: {e}", file=sys.stderr)
            continue

        if not isinstance(sessions, dict) or len(sessions) == 0:
            continue

        for sid, sess in sessions.items():
            model = normalize_model(sess.get("model", "unknown"))
            input_t = sess.get("inputTokens", 0)
            output_t = sess.get("outputTokens", 0)
            total_t = sess.get("totalTokens", 0)

            key = (agent_name, model)
            if key not in grouped:
                grouped[key] = {"input": 0, "output": 0, "total": 0}
            grouped[key]["input"] += input_t
            grouped[key]["output"] += output_t
            grouped[key]["total"] += total_t

    return grouped

def main():
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] sync-usage starting")

    conn = init_db(DB_PATH)
    now = datetime.now(timezone.utc)
    timestamp_ms = int(now.timestamp() * 1000)
    date_str = now.strftime("%Y-%m-%d")
    hour = now.hour

    # Delete existing snapshots for this hour (avoid duplicates, same as usage-collector.ts)
    conn.execute("DELETE FROM usage_snapshots WHERE date = ? AND hour = ?", (date_str, hour))
    conn.commit()

    grouped = collect_sessions()
    count = 0

    for (agent_id, model), tokens in grouped.items():
        cost = calculate_cost(model, tokens["input"], tokens["output"])
        conn.execute(
            """INSERT INTO usage_snapshots
               (timestamp, date, hour, agent_id, model, input_tokens, output_tokens, total_tokens, cost)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (timestamp_ms, date_str, hour, agent_id, model, tokens["input"], tokens["output"], tokens["total"], cost)
        )
        count += 1
        print(f"  {agent_id}/{model}: {tokens['total']:,} tokens, ${cost:.4f}")

    conn.commit()
    conn.close()
    print(f"  Done: {count} snapshots for {date_str} {hour:02d}:00 UTC")

main()
PYEOF

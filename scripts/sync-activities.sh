#!/bin/bash
# sync-activities.sh — Post recent OpenClaw session activity to Mission Control dashboard
# Runs every 5 minutes via cron. Reads sessions.json + cron/jobs.json,
# posts summaries to http://localhost:3000/api/activities
# State file tracks what has already been posted to avoid duplicates.

set -euo pipefail

OPENCLAW_DIR="/home/lmohsin/.openclaw"
AGENTS_DIR="$OPENCLAW_DIR/agents"
CRON_JOBS="$OPENCLAW_DIR/cron/jobs.json"
API_URL="http://localhost:3000/api/activities"
STATE_FILE="/home/lmohsin/mission-control/data/.sync-activities-state.json"
ENV_FILE="/home/lmohsin/mission-control/.env.local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read API key from .env.local
API_KEY=""
if [ -f "$ENV_FILE" ]; then
    API_KEY=$(grep '^AUTH_SECRET=' "$ENV_FILE" | cut -d= -f2-)
fi
export MC_API_KEY="$API_KEY"

# Ensure state file exists
if [ ! -f "$STATE_FILE" ]; then
    echo '{"posted_sessions":{},"last_cron_check_ms":0}' > "$STATE_FILE"
fi

# Use python3 for JSON parsing (jq not available)
python3 << 'PYEOF'
import json, os, sys, time, glob
from urllib.request import Request, urlopen
from urllib.error import URLError

AGENTS_DIR = "/home/lmohsin/.openclaw/agents"
CRON_JOBS = "/home/lmohsin/.openclaw/cron/jobs.json"
API_URL = "http://localhost:3000/api/activities"
STATE_FILE = "/home/lmohsin/mission-control/data/.sync-activities-state.json"
API_KEY = os.environ.get("MC_API_KEY", "")

def post_activity(activity_data):
    """POST an activity to the dashboard API."""
    try:
        data = json.dumps(activity_data).encode("utf-8")
        req = Request(API_URL, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        if API_KEY:
            req.add_header("X-API-Key", API_KEY)
        resp = urlopen(req, timeout=10)
        result = json.loads(resp.read())
        return True
    except Exception as e:
        print(f"  ERROR posting activity: {e}", file=sys.stderr)
        return False

def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {"posted_sessions": {}, "last_cron_check_ms": 0}

def save_state(state):
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)

def classify_session(label):
    """Classify session type from its label."""
    if not label:
        return "task", "Session activity"
    label_lower = label.lower()
    if label_lower.startswith("cron:"):
        return "cron_run", label
    elif "telegram" in label_lower:
        return "message", label
    elif "subagent" in label_lower or "sub-agent" in label_lower:
        return "agent_action", label
    elif "error" in label_lower:
        return "task", label
    else:
        return "task", label

def sync_sessions():
    """Sync recent sessions from all agents."""
    state = load_state()
    posted = state.get("posted_sessions", {})
    new_count = 0

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

        # On first run (no posted sessions), look back 24 hours to seed data
        # On subsequent runs, look back 30 minutes (covers 5-min cron interval + buffer)
        is_first_run = len(posted) == 0
        window_ms = (24 * 60 * 60 * 1000) if is_first_run else (30 * 60 * 1000)
        cutoff_ms = int(time.time() * 1000) - window_ms

        for sid, sess in sessions.items():
            session_id = sess.get("sessionId", sid)
            updated_at = sess.get("updatedAt", 0)

            # Skip if already posted or too old
            state_key = f"{agent_name}:{session_id}"
            if state_key in posted:
                # Check if token count changed significantly (session grew)
                old_tokens = posted[state_key].get("totalTokens", 0)
                new_tokens = sess.get("totalTokens", 0)
                if new_tokens <= old_tokens * 1.1:  # less than 10% growth
                    continue
            elif updated_at < cutoff_ms:
                continue

            label = sess.get("label", "")
            activity_type, description = classify_session(label)
            model = sess.get("model", "unknown")
            input_tokens = sess.get("inputTokens", 0)
            output_tokens = sess.get("outputTokens", 0)
            total_tokens = sess.get("totalTokens", 0)

            # Count messages by checking the JSONL file
            jsonl_file = os.path.join(AGENTS_DIR, agent_name, "sessions", f"{session_id}.jsonl")
            msg_count = 0
            if os.path.isfile(jsonl_file):
                try:
                    with open(jsonl_file) as f:
                        for line in f:
                            try:
                                entry = json.loads(line)
                                if entry.get("type") == "message":
                                    msg_count += 1
                            except json.JSONDecodeError:
                                pass
                except Exception:
                    pass

            # Build description
            if description == "Session activity":
                description = f"Session {session_id[:8]}..."
            desc = f"{description} [{model}] - {total_tokens:,} tokens, {msg_count} messages"

            activity = {
                "type": activity_type,
                "description": desc,
                "status": "success",
                "tokens_used": total_tokens,
                "agent": agent_name,
                "metadata": {
                    "sessionId": session_id,
                    "model": model,
                    "inputTokens": input_tokens,
                    "outputTokens": output_tokens,
                    "messageCount": msg_count,
                }
            }

            if post_activity(activity):
                posted[state_key] = {"totalTokens": total_tokens, "updatedAt": updated_at}
                new_count += 1
                print(f"  Posted: [{agent_name}] {description[:60]}")

    state["posted_sessions"] = posted
    save_state(state)
    return new_count

def sync_cron_jobs():
    """Post activities for recently-run cron jobs."""
    state = load_state()
    last_check = state.get("last_cron_check_ms", 0)
    now_ms = int(time.time() * 1000)
    new_count = 0

    if not os.path.isfile(CRON_JOBS):
        print("  WARN: cron jobs.json not found", file=sys.stderr)
        return 0

    try:
        with open(CRON_JOBS) as f:
            cron_data = json.load(f)
    except Exception as e:
        print(f"  WARN: Cannot parse cron jobs.json: {e}", file=sys.stderr)
        return 0

    jobs = cron_data.get("jobs", [])
    for job in jobs:
        job_name = job.get("name", "Unknown Job")
        job_state = job.get("state", {})
        last_run = job_state.get("lastRunAtMs", 0)
        last_status = job_state.get("lastStatus", "unknown")
        last_duration = job_state.get("lastDurationMs")

        # Only post if the job ran since our last check
        if last_run <= last_check or last_run == 0:
            continue

        # Map status
        status_map = {"ok": "success", "success": "success", "error": "error"}
        mapped_status = status_map.get(last_status, "success" if last_status != "error" else "error")

        schedule = job.get("schedule", {})
        schedule_str = schedule.get("expr", "")

        activity = {
            "type": "cron",
            "description": f"Cron: {job_name} ({schedule_str}) - {last_status}",
            "status": mapped_status,
            "duration_ms": last_duration,
            "agent": "main",
            "metadata": {
                "jobId": job.get("id"),
                "schedule": schedule_str,
                "lastRunAtMs": last_run,
            }
        }

        if post_activity(activity):
            new_count += 1
            print(f"  Posted cron: {job_name} [{last_status}]")

    state["last_cron_check_ms"] = now_ms
    save_state(state)
    return new_count

# Main
print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] sync-activities starting")

session_count = sync_sessions()
cron_count = sync_cron_jobs()

print(f"  Done: {session_count} session activities, {cron_count} cron activities posted")
PYEOF

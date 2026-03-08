import { NextRequest, NextResponse } from "next/server";
import { execSync } from "child_process";

function getGatewayConfig() {
  try {
    const configRaw = require("fs").readFileSync((process.env.OPENCLAW_DIR || "/root/.openclaw") + "/openclaw.json", "utf-8");
    const config = JSON.parse(configRaw);
    return {
      token: config.gateway?.auth?.token || "",
      port: config.gateway?.port || 18789,
    };
  } catch {
    return { token: "", port: 18789 };
  }
}

// GET: List all cron jobs from the OpenClaw gateway
export async function GET() {
  try {
    // Try CLI first, fallback to reading jobs.json directly
    let data: { jobs?: Record<string, unknown>[] } | null = null;

    try {
      const output = execSync("openclaw cron list --json --all 2>/dev/null", {
        timeout: 10000,
        encoding: "utf-8",
      });
      data = JSON.parse(output);
    } catch {
      // CLI not available — read jobs.json directly
      const fs = require("fs");
      const path = require("path");
      const openclawDir = process.env.OPENCLAW_DIR || "/root/.openclaw";
      const jobsPath = path.join(openclawDir, "cron", "jobs.json");
      try {
        const raw = fs.readFileSync(jobsPath, "utf-8");
        data = JSON.parse(raw);
      } catch (fileErr) {
        console.error("Failed to read jobs.json:", fileErr);
      }
    }

    if (!data || !data.jobs) {
      return NextResponse.json([]);
    }

    const jobs = (data.jobs || []).map((job: Record<string, unknown>) => ({
      id: job.id,
      agentId: job.agentId || "main",
      name: job.name || "Unnamed",
      enabled: job.enabled ?? true,
      createdAtMs: job.createdAtMs,
      updatedAtMs: job.updatedAtMs,
      schedule: job.schedule,
      sessionTarget: job.sessionTarget,
      payload: job.payload,
      delivery: job.delivery,
      state: job.state,
      // Derived fields for the UI
      description: formatDescription(job),
      scheduleDisplay: formatSchedule(job.schedule as Record<string, unknown>),
      timezone: (job.schedule as Record<string, string>)?.tz || "UTC",
      nextRun: (job.state as Record<string, unknown>)?.nextRunAtMs
        ? new Date((job.state as Record<string, number>).nextRunAtMs).toISOString()
        : null,
      lastRun: (job.state as Record<string, unknown>)?.lastRunAtMs
        ? new Date((job.state as Record<string, number>).lastRunAtMs).toISOString()
        : null,
    }));

    return NextResponse.json(jobs);
  } catch (error) {
    console.error("Error fetching cron jobs:", error);
    return NextResponse.json(
      { error: "Failed to fetch cron jobs" },
      { status: 500 }
    );
  }
}

function formatDescription(job: Record<string, unknown>): string {
  const payload = job.payload as Record<string, unknown>;
  if (!payload) return "";
  if (payload.kind === "agentTurn") {
    const msg = (payload.message as string) || "";
    return msg.length > 120 ? msg.substring(0, 120) + "..." : msg;
  }
  if (payload.kind === "systemEvent") {
    const text = (payload.text as string) || "";
    return text.length > 120 ? text.substring(0, 120) + "..." : text;
  }
  return "";
}

function formatSchedule(schedule: Record<string, unknown>): string {
  if (!schedule) return "Unknown";
  switch (schedule.kind) {
    case "cron":
      return `${schedule.expr}${schedule.tz ? ` (${schedule.tz})` : ""}`;
    case "every":
      const ms = schedule.everyMs as number;
      if (ms >= 3600000) return `Every ${ms / 3600000}h`;
      if (ms >= 60000) return `Every ${ms / 60000}m`;
      return `Every ${ms / 1000}s`;
    case "at":
      return `Once at ${schedule.at}`;
    default:
      return JSON.stringify(schedule);
  }
}

// PUT: Toggle enable/disable a cron job
export async function PUT(request: NextRequest) {
  try {
    const body = await request.json();
    const { id, enabled } = body;

    if (!id) {
      return NextResponse.json({ error: "Job ID is required" }, { status: 400 });
    }

    const action = enabled ? "enable" : "disable";
    // Use openclaw CLI to update the job
    const output = execSync(
      `openclaw cron ${action} ${id} --json 2>/dev/null || openclaw cron update ${id} --enabled=${enabled} --json 2>/dev/null`,
      { timeout: 10000, encoding: "utf-8" }
    );

    return NextResponse.json({ success: true, id, enabled });
  } catch (error) {
    console.error("Error updating cron job:", error);
    return NextResponse.json(
      { error: "Failed to update cron job" },
      { status: 500 }
    );
  }
}

// DELETE: Remove a cron job
export async function DELETE(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const id = searchParams.get("id");

    if (!id) {
      return NextResponse.json({ error: "Job ID is required" }, { status: 400 });
    }

    execSync(`openclaw cron remove ${id} 2>/dev/null`, {
      timeout: 10000,
      encoding: "utf-8",
    });

    return NextResponse.json({ success: true, deleted: id });
  } catch (error) {
    console.error("Error deleting cron job:", error);
    return NextResponse.json(
      { error: "Failed to delete cron job" },
      { status: 500 }
    );
  }
}

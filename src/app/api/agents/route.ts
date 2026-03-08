import { NextResponse } from "next/server";
import { readFileSync } from "fs";
import { join } from "path";

export const dynamic = "force-dynamic";

interface Agent {
  id: string;
  name?: string;
  emoji: string;
  color: string;
  model: string;
  workspace: string;
  dmPolicy?: string;
  allowAgents?: string[];
  allowAgentsDetails?: Array<{
    id: string;
    name: string;
    emoji: string;
    color: string;
  }>;
  botToken?: string;
  status: "online" | "offline";
  lastActivity?: string;
  activeSessions: number;
}

// Fallback config used when an agent doesn't define its own ui config in openclaw.json.
// The main agent reads name/emoji from env vars; all others fall back to generic defaults.
// Override via each agent's openclaw.json → ui.emoji / ui.color / name fields.
const DEFAULT_AGENT_CONFIG: Record<string, { emoji: string; color: string; name?: string }> = {
  main: {
    emoji: process.env.NEXT_PUBLIC_AGENT_EMOJI || "🤖",
    color: "#ff6b35",
    name: process.env.NEXT_PUBLIC_AGENT_NAME || "Mission Control",
  },
};

/**
 * Get agent display info (emoji, color, name) from openclaw.json or defaults
 */
function getAgentDisplayInfo(agentId: string, agentConfig: any): { emoji: string; color: string; name: string } {
  // First try to get from agent's own config in openclaw.json
  const configEmoji = agentConfig?.ui?.emoji;
  const configColor = agentConfig?.ui?.color;
  const configName = agentConfig?.name;

  // Then try defaults
  const defaults = DEFAULT_AGENT_CONFIG[agentId];

  return {
    emoji: configEmoji || defaults?.emoji || "🤖",
    color: configColor || defaults?.color || "#666666",
    name: configName || defaults?.name || agentId,
  };
}

export async function GET() {
  try {
    // Read openclaw config
    const configPath = (process.env.OPENCLAW_DIR || "/root/.openclaw") + "/openclaw.json";
    const config = JSON.parse(readFileSync(configPath, "utf-8"));

    // Get agents from config
    const agents: Agent[] = config.agents.list.map((agent: any) => {
      const agentInfo = getAgentDisplayInfo(agent.id, agent);

      // Get telegram account info
      const telegramAccount =
        config.channels?.telegram?.accounts?.[agent.id];
      const botToken = telegramAccount?.botToken;

      // Translate container paths to host paths
      const openclawDir = process.env.OPENCLAW_DIR || '/root/.openclaw';
      const hostWorkspace = agent.workspace
        .replace('/home/node/.openclaw', openclawDir)
        .replace('/home/clawdbot/.openclaw', openclawDir);

      // Check if agent has recent activity (memory files + session files)
      const memoryPath = join(hostWorkspace, "memory");
      const sessionsDir = join(openclawDir, "agents", agent.id, "sessions");
      let lastActivity = undefined;
      let status: "online" | "offline" = "offline";
      let latestMtime = 0;

      // Check memory file for today
      try {
        const today = new Date().toISOString().split("T")[0];
        const memoryFile = join(memoryPath, `${today}.md`);
        const stat = require("fs").statSync(memoryFile);
        latestMtime = stat.mtime.getTime();
      } catch (e) {
        // No memory file for today
      }

      // Check sessions.json for recent activity
      try {
        const sessionsFile = join(sessionsDir, "sessions.json");
        const sessionsStat = require("fs").statSync(sessionsFile);
        if (sessionsStat.mtime.getTime() > latestMtime) {
          latestMtime = sessionsStat.mtime.getTime();
        }
        // Also check updatedAt timestamps inside sessions.json
        try {
          const sessionsData = JSON.parse(readFileSync(sessionsFile, "utf-8"));
          for (const key of Object.keys(sessionsData)) {
            const updatedAt = sessionsData[key]?.updatedAt;
            if (typeof updatedAt === "number" && updatedAt > latestMtime) {
              latestMtime = updatedAt;
            }
          }
        } catch (e) {
          // Could not parse sessions.json
        }
      } catch (e) {
        // No sessions.json
      }

      // Check individual session JSONL files (top 5 by mtime)
      try {
        const fs = require("fs");
        const sessionFiles = fs.readdirSync(sessionsDir)
          .filter((f: string) => f.endsWith(".jsonl"))
          .map((f: string) => {
            const fullPath = join(sessionsDir, f);
            return { path: fullPath, mtime: fs.statSync(fullPath).mtime.getTime() };
          })
          .sort((a: any, b: any) => b.mtime - a.mtime)
          .slice(0, 5);
        for (const sf of sessionFiles) {
          if (sf.mtime > latestMtime) {
            latestMtime = sf.mtime;
          }
        }
      } catch (e) {
        // Could not read session files
      }

      if (latestMtime > 0) {
        lastActivity = new Date(latestMtime).toISOString();
        // Consider online if activity within last 15 minutes
        status = Date.now() - latestMtime < 15 * 60 * 1000 ? "online" : "offline";
      }

      // Get details of allowed subagents
      const allowAgents = agent.subagents?.allowAgents || [];
      const allowAgentsDetails = allowAgents.map((subagentId: string) => {
        // Find subagent in config
        const subagentConfig = config.agents.list.find(
          (a: any) => a.id === subagentId
        );
        if (subagentConfig) {
          const subagentInfo = getAgentDisplayInfo(subagentId, subagentConfig);
          return {
            id: subagentId,
            name: subagentConfig.name || subagentInfo.name,
            emoji: subagentInfo.emoji,
            color: subagentInfo.color,
          };
        }
        // Fallback if subagent not found in config
        const fallbackInfo = getAgentDisplayInfo(subagentId, null);
        return {
          id: subagentId,
          name: fallbackInfo.name,
          emoji: fallbackInfo.emoji,
          color: fallbackInfo.color,
        };
      });

      return {
        id: agent.id,
        name: agent.name || agentInfo.name,
        emoji: agentInfo.emoji,
        color: agentInfo.color,
        model:
          agent.model?.primary || config.agents.defaults.model.primary,
        workspace: hostWorkspace,
        dmPolicy:
          telegramAccount?.dmPolicy ||
          config.channels?.telegram?.dmPolicy ||
          "pairing",
        allowAgents,
        allowAgentsDetails,
        botToken: botToken ? "configured" : undefined,
        status,
        lastActivity,
        activeSessions: 0, // TODO: get from sessions API
      };
    });

    return NextResponse.json({ agents });
  } catch (error) {
    console.error("Error reading agents:", error);
    return NextResponse.json(
      { error: "Failed to load agents" },
      { status: 500 }
    );
  }
}

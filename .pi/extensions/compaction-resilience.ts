/**
 * Compaction Resilience Extension for Pi Operators
 *
 * Prevents operators from stalling after Pi context compaction by:
 * 1. Preserving critical operator state (current task, checklist, files being edited)
 *    before compaction occurs
 * 2. Detecting post-compaction stalls and re-engaging the operator
 * 3. Injecting a reminder of what the operator was doing after compaction
 *
 * This extension hooks into Pi's compaction lifecycle:
 * - session_before_compact: Captures and preserves critical state
 * - turn_end: Detects stalls after compaction and re-engages
 * - agent_settled: Handles the case where operator ends idle post-compaction
 *
 * Usage:
 *   pi --extension .pi/extensions/compaction-resilience.ts
 *
 * Or add to settings.json:
 *   "extensions": ["compaction-resilience.ts"]
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// State tracking for compaction resilience
interface OperatorState {
  lastActivity: number;
  filesModified: string[];
  currentTask: string | null;
  checklistItems: string[];
  toolCallCount: number;
  turnCount: number;
  compactionCount: number;
  lastCompactionId: string | null;
}

// Persistent state stored in a custom entry
interface CompactionResilienceState {
  type: "compaction_resilience_state";
  id: string;
  parentId: string | null;
  timestamp: string;
  operatorState: OperatorState;
}

// Default operator state
function createDefaultState(): OperatorState {
  return {
    lastActivity: Date.now(),
    filesModified: [],
    currentTask: null,
    checklistItems: [],
    toolCallCount: 0,
    turnCount: 0,
    compactionCount: 0,
    lastCompactionId: null,
  };
}

// Extract task context from messages
function extractTaskContext(messages: any[]): { task: string | null; checklist: string[] } {
  let task: string | null = null;
  const checklist: string[] = [];

  for (const msg of messages) {
    if (msg.role === "user" || msg.role === "human") {
      // Look for task-like content
      const content = typeof msg.content === "string" ? msg.content : 
        Array.isArray(msg.content) ? msg.content.map((c: any) => c.text || "").join("") : "";
      
      // Extract first substantial user message as task
      if (!task && content.length > 20) {
        task = content.substring(0, 500);
      }
    }

    if (msg.role === "assistant") {
      const content = typeof msg.content === "string" ? msg.content :
        Array.isArray(msg.content) ? msg.content.map((c: any) => c.text || "").join("") : "";
      
      // Look for checklist patterns (e.g., "- [ ] item" or "1. item")
      const checklistMatches = content.match(/^[\s]*[-*]\s*\[[ x]\]\s*.+$/gm) ||
        content.match(/^[\s]*\d+\.\s*.+$/gm);
      if (checklistMatches) {
        checklist.push(...checklistMatches.map((m: string) => m.trim()));
      }
    }
  }

  return { task, checklist: checklist.slice(0, 20) }; // Cap at 20 items
}

// Extract modified files from tool calls
function extractModifiedFiles(messages: any[]): string[] {
  const files = new Set<string>();

  for (const msg of messages) {
    if (msg.role === "assistant" && Array.isArray(msg.tool_calls)) {
      for (const toolCall of msg.tool_calls) {
        if (toolCall.type === "function") {
          const name = toolCall.function?.name;
          const args = toolCall.function?.arguments;
          
          // Only track file-modifying tools
          if (name === "edit" || name === "write") {
            try {
              const parsed = typeof args === "string" ? JSON.parse(args) : args;
              if (parsed.path) files.add(parsed.path);
            } catch {
              // Ignore parse errors
            }
          }
        }
      }
    }
  }

  return Array.from(files);
}

// Generate compaction summary enhancement
function generateCompactionSummary(state: OperatorState): string {
  const lines: string[] = [];
  
  lines.push("\n\n## Operator State (Preserved by compaction-resilience extension)\n");
  
  if (state.currentTask) {
    lines.push(`### Current Task\n${state.currentTask}\n`);
  }
  
  if (state.checklistItems.length > 0) {
    lines.push("### Checklist Progress");
    for (const item of state.checklistItems) {
      lines.push(`- ${item}`);
    }
    lines.push("");
  }
  
  if (state.filesModified.length > 0) {
    lines.push("### Files Being Modified");
    for (const file of state.filesModified) {
      lines.push(`- ${file}`);
    }
    lines.push("");
  }
  
  lines.push(`### Activity Stats`);
  lines.push(`- Tool calls this session: ${state.toolCallCount}`);
  lines.push(`- Turns completed: ${state.turnCount}`);
  lines.push(`- Last activity: ${new Date(state.lastActivity).toISOString()}`);
  
  return lines.join("\n");
}

// Generate post-compaction re-engagement message
function generateReengagementMessage(state: OperatorState): string {
  const lines: string[] = [];
  
  lines.push("**Context was compacted.** Here's what you were working on:");
  
  if (state.currentTask) {
    lines.push(`\n**Task:** ${state.currentTask.substring(0, 200)}${state.currentTask.length > 200 ? "..." : ""}`);
  }
  
  if (state.checklistItems.length > 0) {
    const incomplete = state.checklistItems.filter(item => 
      item.includes("[ ]") || !item.includes("[x]")
    );
    if (incomplete.length > 0) {
      lines.push("\n**Remaining checklist items:**");
      for (const item of incomplete.slice(0, 5)) {
        lines.push(`- ${item}`);
      }
      if (incomplete.length > 5) {
        lines.push(`- ... and ${incomplete.length - 5} more`);
      }
    }
  }
  
  if (state.filesModified.length > 0) {
    lines.push("\n**Files recently modified:**");
    for (const file of state.filesModified.slice(-5)) {
      lines.push(`- ${file}`);
    }
  }
  
  lines.push("\n**Continue your work where you left off.**");
  
  return lines.join("\n");
}

export default function (pi: ExtensionAPI) {
  // Persistent operator state
  let operatorState = createDefaultState();
  let lastCompactionDetected = false;
  let reengagementSent = false;

  // Track tool calls for activity monitoring
  pi.on("tool_call", async (event, ctx) => {
    const toolName = event.toolCall.type === "function" ? event.toolCall.function?.name : "unknown";
    
    // Track file modifications
    if (toolName === "edit" || toolName === "write") {
      try {
        const args = typeof event.toolCall.function?.arguments === "string" 
          ? JSON.parse(event.toolCall.function!.arguments)
          : event.toolCall.function?.arguments;
        if (args?.path) {
          operatorState.filesModified.push(args.path);
          // Keep only last 50 files
          if (operatorState.filesModified.length > 50) {
            operatorState.filesModified = operatorState.filesModified.slice(-50);
          }
        }
      } catch {
        // Ignore parse errors
      }
    }
    
    operatorState.toolCallCount++;
    operatorState.lastActivity = Date.now();
  });

  // Track turn ends
  pi.on("turn_end", async (event, ctx) => {
    operatorState.turnCount++;
    operatorState.lastActivity = Date.now();
    
    // Check if we just had a compaction - set flag for agent_before_settle to handle
    if (lastCompactionDetected && !reengagementSent) {
      // Extract current task context from recent messages
      const branch = ctx.sessionManager.getBranch();
      if (branch) {
        const recentMessages = branch.slice(-10);
        const { task, checklist } = extractTaskContext(recentMessages);
        
        if (task) operatorState.currentTask = task;
        if (checklist.length > 0) operatorState.checklistItems = checklist;
      }
      
      // Flag will be checked by agent_before_settle
      // Don't send re-engagement here to avoid race condition
    }
  });

  // Preserve state before compaction
  pi.on("session_before_compact", async (event, ctx) => {
    const { preparation, signal } = event;
    
    // Extract task context from messages being summarized
    const { task, checklist } = extractTaskContext(preparation.messagesToSummarize);
    
    // Extract modified files
    const modifiedFiles = extractModifiedFiles(preparation.messagesToSummarize);
    
    // Update operator state
    if (task) operatorState.currentTask = task;
    if (checklist.length > 0) {
      // Merge with existing checklist, avoiding duplicates
      const existingSet = new Set(operatorState.checklistItems);
      for (const item of checklist) {
        if (!existingSet.has(item)) {
          operatorState.checklistItems.push(item);
        }
      }
    }
    if (modifiedFiles.length > 0) {
      // Merge with existing files
      const existingSet = new Set(operatorState.filesModified);
      for (const file of modifiedFiles) {
        if (!existingSet.has(file)) {
          operatorState.filesModified.push(file);
        }
      }
    }
    
    operatorState.compactionCount++;
    operatorState.lastActivity = Date.now();
    
    // Store the compaction state as a custom entry
    const stateEntry: CompactionResilienceState = {
      type: "compaction_resilience_state",
      id: `compaction-resilience-${Date.now()}`,
      parentId: null,
      timestamp: new Date().toISOString(),
      operatorState: { ...operatorState },
    };
    
    await ctx.appendEntry(stateEntry);
    
    if (ctx.hasUI) {
      ctx.ui.notify(
        `Preserving operator state before compaction (#${operatorState.compactionCount})`,
        "info"
      );
    }
    
    // Enhance the compaction summary with preserved state
    const stateSummary = generateCompactionSummary(operatorState);
    
    // Return enhanced compaction with our state injected
    return {
      compaction: {
        summary: preparation.previousSummary 
          ? preparation.previousSummary + stateSummary
          : stateSummary,
        firstKeptEntryId: preparation.firstKeptEntryId,
        tokensBefore: preparation.tokensBefore,
        details: {
          readFiles: preparation.fileOps?.readFiles || [],
          modifiedFiles: preparation.fileOps?.modifiedFiles || [],
          compactionResilienceState: operatorState,
        },
      },
    };
  });

  // Handle compaction detection and re-engagement via agent_before_settle
  // agent_before_settle is the final actionable boundary that can append entries and request one continuation
  pi.on("agent_before_settle", async (event, ctx) => {
    // Check if we're settling after a compaction
    const branch = ctx.sessionManager.getBranch();
    if (!branch) return;
    
    // Look for recent compaction entry
    const recentCompaction = branch
      .slice(-5)
      .find(entry => entry.type === "compaction");
    
    if (recentCompaction && recentCompaction.id !== operatorState.lastCompactionId) {
      // New compaction detected
      operatorState.lastCompactionId = recentCompaction.id;
      lastCompactionDetected = true;
      reengagementSent = false;
      
      if (ctx.hasUI) {
        ctx.ui.notify("Compaction detected - will re-engage", "info");
      }
    }
    
    // Check for idle state after compaction (potential stall)
    const timeSinceLastActivity = Date.now() - operatorState.lastActivity;
    const idleThreshold = 5000; // 5 seconds
    
    if (lastCompactionDetected && timeSinceLastActivity > idleThreshold && !reengagementSent) {
      // Operator seems idle after compaction - send re-engagement
      const reengagementMsg = generateReengagementMessage(operatorState);
      
      // Use pi.sendUserMessage (on ExtensionAPI) instead of ctx.sendUserMessage
      // agent_before_settle can request one continuation via return { continue: true }
      // but we need to send a message to re-engage the operator
      pi.sendUserMessage(reengagementMsg, { deliverAs: "followUp" });
      
      reengagementSent = true;
      lastCompactionDetected = false;
      
      if (ctx.hasUI) {
        ctx.ui.notify("Post-compaction stall detected - sending re-engagement", "warning");
      }
    }
  });

  // Load persisted state on session start
  pi.on("session_start", async (event, ctx) => {
    const branch = ctx.sessionManager.getBranch();
    if (!branch) return;
    
    // Find most recent compaction resilience state
    const stateEntry = branch
      .filter((entry): entry is CompactionResilienceState => 
        entry.type === "compaction_resilience_state"
      )
      .pop();
    
    if (stateEntry) {
      operatorState = { ...stateEntry.operatorState };
      if (ctx.hasUI) {
        ctx.ui.notify(
          `Loaded operator state: ${operatorState.compactionCount} compactions tracked`,
          "info"
        );
      }
    }
  });

  // Register command to manually check state
  pi.registerCommand("compaction-status", {
    description: "Show compaction resilience status",
    handler: async (args, ctx) => {
      const lines = [
        "## Compaction Resilience Status",
        `- Compactions tracked: ${operatorState.compactionCount}`,
        `- Turns completed: ${operatorState.turnCount}`,
        `- Tool calls: ${operatorState.toolCallCount}`,
        `- Files modified: ${operatorState.filesModified.length}`,
        `- Last activity: ${new Date(operatorState.lastActivity).toISOString()}`,
        `- Current task: ${operatorState.currentTask ? "Set" : "Not set"}`,
        `- Checklist items: ${operatorState.checklistItems.length}`,
      ];
      
      if (args === "--reset") {
        operatorState = createDefaultState();
        lines.push("\n**State reset.**");
      }
      
      ctx.ui.notify(lines.join("\n"), "info");
    },
  });

  // Register command to manually trigger re-engagement
  pi.registerCommand("compaction-reengage", {
    description: "Manually trigger post-compaction re-engagement",
    handler: async (args, ctx) => {
      const reengagementMsg = generateReengagementMessage(operatorState);
      pi.sendUserMessage(reengagementMsg, { deliverAs: "followUp" });
      ctx.ui.notify("Re-engagement message sent", "info");
    },
  });
}

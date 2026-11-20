import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { delegate } from "./delegate.ts";
import { doctor } from "./doctor.ts";
import { generate } from "./generate.ts";
import { hooks } from "./hooks.ts";
import { memory } from "./memory.ts";
import { commit, mode } from "./mode.ts";
import { models } from "./models.ts";
import { orchestrator } from "./orchestrator.ts";

const repo = process.env.NC_REPO ?? resolve(dirname(import.meta.path), "..");
const home = process.env.HOME ?? homedir();

const HELP = `nc – shared commands of nc-harness

  nc claude [ARGS]     start Claude Code with model and effort of claude_code.orchestrator (models.yaml)
  nc delegate …        a task to an OpenCode worker in its own nc-work task; in a task through the broker (nc delegate help)
  nc doctor [--json]   check the installation (direct on the host or isolated in nc-work)
  nc generate [--check]  write the agent files (subagents) for Claude Code and OpenCode
                       from roles/ and models.yaml, and the MCP files from mcp/servers.yaml
  nc generate --out DIR --path PROJECT_PATH [--check]
                       the agents for a task container (nc-work): DIR/claude, DIR/opencode, policy of PROJECT_PATH; no MCP
  nc hooks [--check]   the harness's Claude Code hooks in ~/.claude/settings.json (SessionStart compact:
                       restores an open orchestrator run after a compaction)
  nc memory …          shared memory: show, search, add, sync, apply (nc memory help)
  nc models …          what models.yaml allows in a folder: show, resolve, check, orchestrator (nc models help)
  nc opencode [ARGS]   start OpenCode with the OpenRouter key for this process only
  nc orchestrator OVERLAY
                       the orchestrator's procedure: orchestrator/base.md plus overlays/OVERLAY.md (claude)
  nc orchestrator status crew|plan|state|task|clear|context …
                       publish the orchestrator's state for the herdr card (~/.claude/nc-orchestrator/<session>.json)
  nc version           harness commit and mode
  nc help              this text
`;

const [cmd, ...args] = process.argv.slice(2);

switch (cmd) {
  case "delegate":
    process.exit(delegate(repo, home, args));
  case "doctor":
    process.exit(doctor(repo, home, args));
  case "generate":
    process.exit(generate(repo, home, args));
  case "memory":
    process.exit(memory(repo, home, args));
  case "models":
    process.exit(models(repo, args));
  case "hooks":
    process.exit(hooks(home, args));
  case "orchestrator":
    process.exit(orchestrator(repo, home, args));
  case "version":
    console.log(`nc-harness ${commit(repo)} ${mode()}`);
    break;
  case "opencode":
  case "claude":
    // bin/nc hands these to cli/opencode.sh and cli/claude.sh before Bun starts; only reached when cli/nc.ts runs directly.
    process.stderr.write(`nc ${cmd}: start it through bin/nc\n`);
    process.exit(2);
  case undefined:
  case "help":
  case "-h":
  case "--help":
    process.stdout.write(HELP);
    break;
  default:
    process.stderr.write(`nc: unknown command: ${cmd}\n\n${HELP}`);
    process.exit(2);
}

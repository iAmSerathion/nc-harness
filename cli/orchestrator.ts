/**
 * nc orchestrator <overlay> – the orchestrator's procedure: orchestrator/base.md, an empty line, then
 * orchestrator/overlays/<overlay>.md. The skill crew (Claude Code) runs `nc orchestrator claude`.
 * Claude Code is the only orchestrator, so only overlays/claude.md exists; a new runtime would add its own overlay.
 *
 * Reads only, the same on the host and in a task container (there from the snapshot under /opt/nc-harness). Exit 2: an overlay name that is not of the form of a role name, or a missing file. No silent fallback
 * to base.md alone.
 *
 * nc orchestrator status … is the writer of the card's status file (orchestrator-status.ts); "status" is therefore
 * reserved and never an overlay name.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ModelsError, ROLE_NAME } from "./models.ts";
import { orchestratorStatus } from "./orchestrator-status.ts";

const q = (v: unknown) => JSON.stringify(v) ?? String(v);

function read(repo: string, file: string): string {
  try {
    return readFileSync(join(repo, file), "utf8");
  } catch (e: any) {
    throw new ModelsError(`${file} missing or not readable (${e?.code ?? e})`);
  }
}

/** base.md + empty line + overlays/<overlay>.md, each without trailing whitespace, ending in one newline. */
export function orchestratorText(repo: string, overlay: string): string {
  if (!ROLE_NAME.test(overlay) || overlay === "status") throw new ModelsError(`overlay ${q(overlay)} does not have the form ${ROLE_NAME.source}`);
  const base = read(repo, "orchestrator/base.md").replace(/\s+$/, "");
  const extra = read(repo, `orchestrator/overlays/${overlay}.md`).replace(/\s+$/, "");
  return `${base}\n\n${extra}\n`;
}

export function orchestrator(repo: string, home: string, args: string[]): number {
  if (args[0] === "status") return orchestratorStatus(home, args.slice(1));
  if (args.length !== 1) {
    process.stderr.write("nc orchestrator: give exactly one overlay, e.g. nc orchestrator claude\n");
    return 2;
  }
  try {
    process.stdout.write(orchestratorText(repo, args[0]));
    return 0;
  } catch (e: any) {
    process.stderr.write(`nc orchestrator: ${e instanceof ModelsError ? e.message : `unexpected error: ${e?.message ?? e}`}\n`);
    return 2;
  }
}

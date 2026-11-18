/**
 * nc hooks [--check] – the Claude Code hooks of the harness in ~/.claude/settings.json. install.sh runs it, nc doctor
 * checks it. Today one hook: SessionStart with matcher "compact" runs `nc orchestrator status context`, which puts an
 * open orchestrator run back into the context after a compaction (cli/orchestrator-status.ts).
 *
 * Only our entry is touched: it is found by its command, added when missing and replaced when it differs; every
 * other key and hook stays as it is. A settings.json that is not valid JSON is never overwritten (exit 2). Before a
 * change the old file is copied to ~/.nc/backup/<date>/.claude/settings.json. A link is followed, the file it
 * points to is written (tmp file next to it, then rename, same mode).
 *
 * Exit 0: up to date or written. 1: --check and something to do. 2: error.
 */
import { copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const MARK = "orchestrator status context";
export const COMPACT_HOOK = {
  matcher: "compact",
  hooks: [{ type: "command", command: `"$HOME/.local/bin/nc" ${MARK}`, timeout: 10 }],
};

type Entry = { matcher?: unknown; hooks?: unknown };
const ours = (e: Entry) => Array.isArray(e?.hooks) && e.hooks.some((h: any) => typeof h?.command === "string" && h.command.includes(MARK));

const say = (what: string, detail: string) => console.log(`  ${what.padEnd(10)} ${detail}`);
const WHAT = "~/.claude/settings.json: SessionStart compact hook (nc orchestrator status context)";

export class HooksError extends Error {}

/** Parses settings.json (a missing file is {}); throws HooksError when it is not a JSON object. */
export function parseSettings(text: string | null): Record<string, any> {
  if (text === null || !text.trim()) return {};
  let s: unknown;
  try {
    s = JSON.parse(text);
  } catch (e: any) {
    throw new HooksError(`not valid JSON (${e?.message ?? e}) – fix it by hand, nothing written`);
  }
  if (!s || typeof s !== "object" || Array.isArray(s)) throw new HooksError("not a JSON object – fix it by hand, nothing written");
  return s as Record<string, any>;
}

/** "ok" when exactly our entry is there, else what is wrong with it. */
export function hookState(s: Record<string, any>): "ok" | "missing" | "outdated" {
  const list = s.hooks?.SessionStart;
  const found = Array.isArray(list) ? list.filter(ours) : [];
  if (!found.length) return "missing";
  return found.length === 1 && JSON.stringify(found[0]) === JSON.stringify(COMPACT_HOOK) ? "ok" : "outdated";
}

/** The settings with our entry in place: other SessionStart entries keep their order, ours comes last. */
export function withHook(s: Record<string, any>): Record<string, any> {
  if (s.hooks !== undefined && (!s.hooks || typeof s.hooks !== "object" || Array.isArray(s.hooks)))
    throw new HooksError('"hooks" is not an object – fix it by hand, nothing written');
  const hooks = { ...(s.hooks ?? {}) };
  const start = hooks.SessionStart;
  if (start !== undefined && !Array.isArray(start)) throw new HooksError('"hooks.SessionStart" is not a list – fix it by hand, nothing written');
  hooks.SessionStart = [...(start ?? []).filter((e: Entry) => !ours(e)), COMPACT_HOOK];
  return { ...s, hooks };
}

export function hooks(home: string, args: string[]): number {
  const check = args.includes("--check");
  const bad = args.filter((a) => a !== "--check");
  if (bad.length) {
    process.stderr.write(`nc hooks: unknown argument ${JSON.stringify(bad[0])}\nusage: nc hooks [--check]\n`);
    return 2;
  }
  const link = join(home, ".claude", "settings.json");
  let file = link;
  try {
    if (existsSync(link)) file = realpathSync(link);
    const text = existsSync(file) ? readFileSync(file, "utf8") : null;
    const s = parseSettings(text);
    const state = hookState(s);
    if (state === "ok") {
      say("ok", WHAT);
      return 0;
    }
    if (check) {
      say(state === "missing" ? "add" : "update", WHAT);
      return 1;
    }
    const next = `${JSON.stringify(withHook(s), null, 2)}\n`;
    if (text !== null) {
      const d = new Date();
      const day = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
      let backup = join(home, ".nc", "backup", day, ".claude", "settings.json");
      if (existsSync(backup)) backup += `.${d.toTimeString().slice(0, 8).replace(/:/g, "")}`;
      mkdirSync(dirname(backup), { recursive: true });
      copyFileSync(file, backup);
    }
    const tmp = `${file}.nc-${process.pid}.tmp`;
    try {
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(tmp, next, { mode: text === null ? 0o600 : statSync(file).mode & 0o777 });
      renameSync(tmp, file);
    } catch (e) {
      try { unlinkSync(tmp); } catch { /* not written */ }
      throw e;
    }
    say(state === "missing" ? "added" : "updated", WHAT);
    return 0;
  } catch (e: any) {
    process.stderr.write(`nc hooks: ~/.claude/settings.json: ${e instanceof HooksError ? e.message : e?.code ?? e?.message ?? e}\n`);
    return 2;
  }
}

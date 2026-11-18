/**
 * nc hooks [--check] – the Claude Code hooks of the harness in ~/.claude/settings.json. install.sh runs it, nc doctor
 * checks it. Today one hook: SessionStart with matcher "compact" runs `nc orchestrator status context`, which puts an
 * open orchestrator run back into the context after a compaction (cli/orchestrator-status.ts).
 *
 * Only our entry is touched: it is found by its command, added when missing and replaced when it differs; every
 * other key and hook stays as it is. A settings.json that is not valid JSON is never overwritten (exit 2). Before a
 * change the old file is copied to ~/.nc/backup/<date>/.claude/settings.json. A link is followed, the file it
 * points to is written (tmp file next to it, then rename, same mode); a dangling link is refused. Our hook shares
 * no entry: when it sits in one with other hooks, only it is taken out of there.
 *
 * Exit 0: up to date or written. 1: --check and something to do. 2: error.
 */
import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const MARK = "orchestrator status context";
export const COMPACT_HOOK = {
  matcher: "compact",
  hooks: [{ type: "command", command: `"$HOME/.local/bin/nc" ${MARK}`, timeout: 10 }],
};

type Hook = { command?: unknown };
const isOurs = (h: Hook) => typeof h?.command === "string" && h.command.includes(MARK);

const say = (what: string, detail: string) => console.log(`  ${what.padEnd(10)} ${detail}`);
const WHAT = "~/.claude/settings.json: SessionStart compact hook (nc orchestrator status context)";

export class HooksError extends Error {}

/** Parses settings.json (a missing file is {}, a leading BOM is dropped); throws HooksError when it is not a JSON
 * object or "hooks" / "hooks.SessionStart" have a shape the write would refuse, so --check and doctor agree with it. */
export function parseSettings(text: string | null): Record<string, any> {
  if (text === null || !text.trim()) return {};
  let s: any;
  try {
    s = JSON.parse(text.replace(/^\uFEFF/, ""));
  } catch (e: any) {
    throw new HooksError(`not valid JSON (${e?.message ?? e}) – fix it by hand, nothing written`);
  }
  if (!s || typeof s !== "object" || Array.isArray(s)) throw new HooksError("not a JSON object – fix it by hand, nothing written");
  if (s.hooks !== undefined && (!s.hooks || typeof s.hooks !== "object" || Array.isArray(s.hooks)))
    throw new HooksError('"hooks" is not an object – fix it by hand, nothing written');
  if (s.hooks?.SessionStart !== undefined && !Array.isArray(s.hooks.SessionStart))
    throw new HooksError('"hooks.SessionStart" is not a list – fix it by hand, nothing written');
  return s;
}

/** "ok" when our hook is there exactly once, alone in an entry equal to COMPACT_HOOK; else what is wrong. */
export function hookState(s: Record<string, any>): "ok" | "missing" | "outdated" {
  const entries: any[] = s.hooks?.SessionStart ?? [];
  const count = entries.reduce((n, e) => n + (Array.isArray(e?.hooks) ? e.hooks.filter(isOurs).length : 0), 0);
  if (!count) return "missing";
  return count === 1 && entries.some((e) => JSON.stringify(e) === JSON.stringify(COMPACT_HOOK)) ? "ok" : "outdated";
}

/** The settings with our entry in place: our hook is taken out of every entry (an entry left empty goes), every
 * other hook and entry keeps its place, COMPACT_HOOK comes last. parseSettings has checked the shape. */
export function withHook(s: Record<string, any>): Record<string, any> {
  const start = (s.hooks?.SessionStart ?? []).flatMap((e: any) => {
    if (!Array.isArray(e?.hooks) || !e.hooks.some(isOurs)) return [e];
    const rest = e.hooks.filter((h: Hook) => !isOurs(h));
    return rest.length ? [{ ...e, hooks: rest }] : [];
  });
  return { ...s, hooks: { ...(s.hooks ?? {}), SessionStart: [...start, COMPACT_HOOK] } };
}

/** The real settings file (a link followed) and its text (null when missing); a dangling link is a HooksError. */
export function readSettings(home: string): { file: string; text: string | null } {
  const link = join(home, ".claude", "settings.json");
  if (!lstatSync(link, { throwIfNoEntry: false })?.isSymbolicLink()) return { file: link, text: existsSync(link) ? readFileSync(link, "utf8") : null };
  if (!existsSync(link)) throw new HooksError("is a link to a missing file – create the target or remove the link, nothing written");
  return { file: realpathSync(link), text: readFileSync(link, "utf8") };
}

export function hooks(home: string, args: string[]): number {
  const check = args.includes("--check");
  const bad = args.filter((a) => a !== "--check");
  if (bad.length) {
    process.stderr.write(`nc hooks: unknown argument ${JSON.stringify(bad[0])}\nusage: nc hooks [--check]\n`);
    return 2;
  }
  try {
    const { file, text } = readSettings(home);
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
      // shortcut: no lock against Claude Code or Orca writing at the same moment; a change seen here stops the write
      const now = existsSync(file) ? readFileSync(file, "utf8") : null;
      if (now !== text) throw new HooksError("changed while nc hooks ran – run it again, nothing written");
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

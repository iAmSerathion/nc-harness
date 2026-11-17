import { existsSync, lstatSync, readdirSync, readFileSync, readlinkSync } from "node:fs";
import { join } from "node:path";
import { mode } from "./mode.ts";

export type Entry =
  | { kind: "dir"; target: string }
  | { kind: "link"; target: string; source: string }
  | { kind: "skills"; target: string; source: string };

/** Skill folder names: lowercase words joined by single hyphens (Agent Skills format). */
export const SKILL_NAME = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/**
 * Parse manifest.txt (same format install.sh reads). Paths are returned absolute. A link line with the third word
 * `overlay` points to ~/.nc/overlay/<source> when that file exists (host only; in a container the agent owns HOME).
 */
export function readManifest(repo: string, home: string): Entry[] {
  const text = readFileSync(join(repo, "manifest.txt"), "utf8");
  const entries: Entry[] = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const [kind, a, b, c] = line.split(/\s+/);
    if (kind === "dir" && a) entries.push({ kind, target: join(home, a) });
    else if (kind === "link" && a && b && (c === undefined || c === "overlay")) {
      const overlay = join(home, ".nc/overlay", b);
      entries.push({ kind, target: join(home, a), source: c && mode() === "direct" && existsSync(overlay) ? overlay : join(repo, b) });
    } else if (kind === "skills" && a && b && c === undefined)
      entries.push({ kind, target: join(home, a), source: join(repo, b) });
    else throw new Error(`bad manifest line: ${line}`);
  }
  return entries;
}

/** Names of the skills in a repo folder: every real subfolder (not a link) with a SKILL.md and a valid name. */
export function skillNames(source: string): string[] {
  if (!existsSync(source)) return [];
  return readdirSync(source, { withFileTypes: true })
    .filter((d) => d.isDirectory() && SKILL_NAME.test(d.name) && existsSync(join(source, d.name, "SKILL.md")))
    .map((d) => d.name)
    .sort();
}

/** A `skills` entry becomes one link per skill: <target>/<name> -> <source>/<name>. */
export function expandSkills(e: { target: string; source: string }): { kind: "link"; target: string; source: string }[] {
  return skillNames(e.source).map((name) => ({ kind: "link", target: join(e.target, name), source: join(e.source, name) }));
}

/** Links in <target> that point into <source> but whose skill folder is gone (install.sh removes them). */
export function staleSkillLinks(e: { target: string; source: string }): string[] {
  if (!existsSync(e.target)) return [];
  const stale: string[] = [];
  for (const name of readdirSync(e.target)) {
    const path = join(e.target, name);
    try {
      if (!lstatSync(path).isSymbolicLink()) continue;
    } catch {
      continue;
    }
    const to = readlinkSync(path);
    if (to.startsWith(e.source + "/") && !existsSync(join(to, "SKILL.md"))) stale.push(path);
  }
  return stale;
}

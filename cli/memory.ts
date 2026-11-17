/**
 * nc memory – the shared memory. Direct on the host it reads and writes the checkout of the memory repo
 * (NC_MEMORY_REMOTE at install) in ~/.nc/memory. Isolated in an nc-work task it reads the read-only view nc-work
 * mounted (NC_MEMORY_DIR: MEMORY.md, global/, projects/<own project>.md) and hands notes to the host, which takes
 * the project from its own records, never from the request:
 *
 * - Through the broker: `add` puts {"v":1,"type":"memory","text":"…"} (plus an optional
 *   "replaces") into the task's mailbox (NC_REQUESTS) and waits for the answer in the read-only inbox (NC_INBOX).
 *   `nc-work broker` calls `nc memory apply --broker` on the host, which commits and pushes, then refreshes the view.
 * - Fallback, the outbox (NC_MEMORY_OUTBOX): only if the task has no mailbox, the heartbeat is old before posting, or
 *   the client took its request back (the broker never got it). One JSON file per note: {"v":1,"ts":"<ISO time>",
 *   "text":"…"} plus an optional "replaces". `nc-work memory-apply` applies them (`nc memory apply --outbox`).
 *
 * Any other field, above all "project", gets a request rejected. Every writing command on the host (add, sync,
 * apply) runs under flock(1) on the folder ~/.nc/memory itself: bin/nc re-runs itself under `flock -x` with
 * NC_MEMORY_LOCKED=1, like nc delegate's fetching (Bun has no flock). A lock file in the checkout would make it dirty.
 */
import { closeSync, existsSync, lstatSync, openSync, readdirSync, readFileSync, renameSync, unlinkSync, writeFileSync, writeSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { join, relative } from "node:path";
import { answerMs, awaitAnswer, brokerAlive, DelegateError, mailbox, post, reasonOf, Refused, TakenBack, type Mailbox } from "./delegate.ts";
import { mode, ncHome } from "./mode.ts";
import { parseObject, readBounded, REASON_CHARS, rejectUnknown, RequestError } from "./request.ts";
import { INVISIBLE, visible } from "./sanitize.ts";

export const LIMITS = { note: 500, projectLines: 100, indexLines: 150, requestBytes: 8192, requestsPerRun: 50 };
/** Project names are nc-infra's profile names (and host-only projects like nc-harness). */
export const PROJECT = /^[a-z][a-z0-9-]{0,39}$/;
/** A cheap tripwire, not protection: the rule "no keys in memory" holds regardless. */
const SECRETS: [RegExp, string][] = [
  [/\bsk-[A-Za-z0-9_-]{8,}/, "sk-…"],
  [/\bghp_[A-Za-z0-9]{8,}/, "ghp_…"],
  [/\bgithub_pat_/, "github_pat_…"],
  [/-----BEGIN/, "-----BEGIN"],
  [/API_KEY\s*=/i, "API_KEY="],
  [/\bxox[abprs]-[A-Za-z0-9-]{8,}/, "xox…-"],
  [/\bAKIA[0-9A-Z]{16}\b/, "AKIA…"],
];
const NOTE_LINE = /^- (\d{4}-\d{2}-\d{2}): (.*)$/;
const REQUEST_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/;
const REQUEST_KEYS = new Set(["v", "ts", "text", "replaces"]);
/** A memory request in the broker's mailbox: no ts, no project, nothing else. */
const BROKER_KEYS = new Set(["v", "type", "text", "replaces"]);
const OUTCOMES: Outcome[] = ["new", "refreshed", "replaced", "unchanged"];
export { visible };

/** A refusal meant for the user: printed as "nc memory: …", exit 1. */
export class MemoryError extends Error {}

/** A line prefix copied along from `nc memory show` ("- 2026-11-16: "), once or several times. The date is added on write. */
const DATE_PREFIX = /^(?:-\s*)?\d{4}-\d{2}-\d{2}:\s*/;
const stripDates = (t: string) => {
  while (DATE_PREFIX.test(t)) t = t.replace(DATE_PREFIX, "");
  return t;
};

/**
 * Whitespace collapsed to single spaces, a copied "- YYYY-MM-DD: " prefix cut off (otherwise the line would carry
 * the date twice, and a whole line given as --replaces would match nothing). Empty, control or invisible
 * characters, too long or secret-like: refused whole.
 */
export function checkNote(raw: string, what = "note"): string {
  const hidden = raw.match(INVISIBLE)?.[0];  // checked before \s collapses U+FEFF into a space
  if (hidden) throw new MemoryError(`${what} contains invisible characters (U+${hidden.codePointAt(0)!.toString(16).toUpperCase().padStart(4, "0")}) – nothing written`);
  const text = stripDates(raw.replace(/\s+/g, " ").trim());
  if (!text) throw new MemoryError(`empty ${what}`);
  if (/[\u0000-\u001f\u007f-\u009f]/.test(text)) throw new MemoryError(`${what} contains control characters – nothing written`);
  const len = [...text].length;
  if (len > LIMITS.note) throw new MemoryError(`${what} has ${len} characters, at most ${LIMITS.note} – nothing written`);
  for (const [re, label] of SECRETS)
    if (re.test(text)) throw new MemoryError(`${what} looks like a secret (${label}) – nothing written; keys never belong in the memory`);
  return text;
}

export function today(d = new Date()): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export type Outcome = "new" | "refreshed" | "replaced" | "unchanged";
export type Note = { text: string; replaces?: string };

/**
 * One note into the lines of a project file. Same text (ignoring case) as an existing note: that note gets
 * today's date instead of a duplicate. `replaces`: that note is rewritten, and it must exist, unless the new
 * text is already there and the old one gone (a repeated request: done). If the new text exists as another
 * note, the old one is dropped – but only direct on the host; a request from a task (`fromTask`) never
 * deletes a note. Changes `lines` only if the result stays within the line limit.
 */
export function applyNote(lines: string[], note: Note, date: string, fromTask = false): Outcome {
  // A stored note may still carry a doubled date from before checkNote cut it off: compared without it.
  const key = (t: string) => stripDates(t).toLowerCase();
  const find = (t: string) => lines.findIndex((l) => key(l.match(NOTE_LINE)?.[2] ?? "\0") === key(t));
  const next = [...lines];
  let outcome: Outcome;
  const same = find(note.text);
  if (note.replaces !== undefined) {
    const old = find(note.replaces);
    if (old < 0 && same >= 0 && fromTask) return "unchanged";  // direct, this is more likely a typo in --replaces
    if (old < 0) throw new MemoryError(`note to replace not found: "${note.replaces.slice(0, 60)}"`);
    if (same >= 0 && same !== old) {
      if (fromTask)
        throw new MemoryError(`the new text is already there as a note of its own; "${note.replaces.slice(0, 60)}" would be deleted without replacement – a request from a task deletes no note`);
      next[same] = `- ${date}: ${next[same].match(NOTE_LINE)![2]}`;
      next.splice(old, 1);
    } else {
      if (next[old] === `- ${date}: ${note.text}`) return "unchanged";
      next[old] = `- ${date}: ${note.text}`;
    }
    outcome = "replaced";
  } else if (same >= 0) {
    const [, d, text] = next[same].match(NOTE_LINE)!;
    if (d === date) return "unchanged";
    next[same] = `- ${date}: ${text}`;
    outcome = "refreshed";
  } else {
    next.push(`- ${date}: ${note.text}`);
    outcome = "new";
  }
  if (next.length > LIMITS.projectLines)
    throw new MemoryError(`project file would have ${next.length} lines, at most ${LIMITS.projectLines} – nothing written; remove outdated notes first`);
  lines.splice(0, lines.length, ...next);
  return outcome;
}

const splitLines = (text: string) => (text.endsWith("\n") ? text.slice(0, -1) : text).split("\n");
export const lineCount = (text: string) => (text === "" ? 0 : splitLines(text).length);

function isDir(p: string): boolean {
  try {
    return lstatSync(p).isDirectory();
  } catch {
    return false;
  }
}

function isFile(p: string): boolean {
  try {
    return lstatSync(p).isFile();
  } catch {
    return false;
  }
}

/** Regular .md files below dir, sorted, relative paths. Links and .git are skipped. */
function mdFiles(dir: string, sub = ""): string[] {
  const out: string[] = [];
  let entries;
  try {
    entries = readdirSync(join(dir, sub), { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const rel = sub ? `${sub}/${e.name}` : e.name;
    if (e.isDirectory() && e.name !== ".git") out.push(...mdFiles(dir, rel));
    else if (e.isFile() && e.name.endsWith(".md")) out.push(rel);
  }
  return out;
}

// --- git (direct mode only) ---------------------------------------------------------------------

/** Never throws: a failed spawn (E2BIG, git missing) is ok: false like a failed git. `input` goes to stdin. */
function git(dir: string, args: string[], input?: string) {
  let r;
  try {
    r = Bun.spawnSync(["git", "-C", dir, ...args], { stdin: input === undefined ? "ignore" : Buffer.from(input), stdout: "pipe", stderr: "pipe", timeout: 60_000 });
  } catch (e: any) {
    return { ok: false, out: "", err: `git not started (${e?.code ?? e?.message ?? e})` };
  }
  const out = r.stdout.toString().trim();
  return { ok: r.success, out, err: (r.stderr.toString().trim() || out).split("\n")[0] ?? "" };
}

/** The checkout is there, has a commit and a remote, and holds no uncommitted changes. */
function readyToWrite(dir: string, tilde: string, check = () => {}) {
  if (!isDir(join(dir, ".git"))) throw new MemoryError(`${tilde} missing or not a git checkout – ./install.sh`);
  check();
  if (!git(dir, ["rev-parse", "--verify", "-q", "HEAD"]).ok) throw new MemoryError(`${tilde} has no commit yet`);
  check();
  if (!git(dir, ["remote", "get-url", "origin"]).ok) throw new MemoryError(`${tilde} has no remote origin`);
  check();
  if (git(dir, ["status", "--porcelain"]).out) throw new MemoryError(`uncommitted changes in ${tilde} – commit or discard them first, nothing written`);
}

/** `check` runs before the pull only, never before the rebase --abort that cleans up after it. */
function pull(dir: string, check = () => {}) {
  check();
  const r = git(dir, ["pull", "--rebase", "-q"]);
  if (r.ok) return;
  git(dir, ["rebase", "--abort"]);
  throw new MemoryError(`git pull --rebase failed (conflict or no network), nothing written: ${r.err}`);
}

const PUSH_FAILED = "committed locally, but the push failed – nc memory sync later";

/**
 * Commit the file and push; one retry after a fresh pull if someone pushed in between. False: committed, not
 * pushed. If the commit fails, the file is reset to HEAD first: a staged leftover would block every later write
 * for all projects (one shared checkout). `inTime` (apply --broker) is asked before every git call: false before
 * the add or the commit undoes the file the same way and throws (nothing written); false before a push or the
 * retry's pull means no further git call is started – committed, not pushed.
 */
function commitAndPush(dir: string, file: string, message: string, inTime = () => true): boolean {
  const undo = (what: string, detail?: string): never => {
    const undone = git(dir, ["reset", "-q", "--", file]).ok && git(dir, ["checkout", "-q", "--", file]).ok;
    throw new MemoryError(undone
      ? `${what}, nothing written${detail === undefined ? "" : `: ${detail}`}`
      : `${what}${detail === undefined ? "" : ` (${detail})`}, and resetting ${file} failed too – check the checkout by hand (git status)`);
  };
  const late = "deadline passed (lock or git too slow)";
  if (!inTime()) undo(`${late} before git add`);
  const add = git(dir, ["add", "--", file]);
  if (add.ok && !inTime()) undo(`${late} before git commit`);
  const commit = add.ok ? git(dir, ["commit", "-q", "-F", "-"], message) : add;  // stdin: no limit on the message
  if (!commit.ok) undo("git commit failed", commit.err || "without a message");
  if (!inTime()) return false;
  if (git(dir, ["push", "-q", "origin", "HEAD"]).ok) return true;
  if (!inTime()) return false;
  const again = git(dir, ["pull", "--rebase", "-q"]);
  if (!again.ok) git(dir, ["rebase", "--abort"]);
  if (!again.ok || !inTime()) return false;
  return git(dir, ["push", "-q", "origin", "HEAD"]).ok;
}

function projectFile(dir: string, project: string): string {
  if (!PROJECT.test(project)) throw new MemoryError(`invalid project name: ${project}`);
  const file = join(dir, "projects", `${project}.md`);
  if (!isFile(file)) throw new MemoryError(`no memory for project ${project} (projects/${project}.md missing) – nothing written`);
  return file;
}

// --- requests (outbox) ----------------------------------------------------------------------------

/** Read and check one request. Never follows links, never blocks on a FIFO, never trusts a field (cli/request.ts). */
export function readRequest(path: string): Note {
  let req: Record<string, unknown>;
  try {
    req = parseObject(readBounded(path, LIMITS.requestBytes));
    if ("project" in req) throw new MemoryError("contains a project field – the host sets the project, not the request");
    rejectUnknown(req, REQUEST_KEYS);
  } catch (e) {
    if (e instanceof RequestError) throw new MemoryError(e.message);
    throw e;
  }
  if (req.v !== 1) throw new MemoryError(`version ${String(JSON.stringify(req.v)).slice(0, 40)} unknown, expected 1`);
  if (typeof req.ts !== "string" || Number.isNaN(Date.parse(req.ts))) throw new MemoryError("ts missing or not a time");
  if (typeof req.text !== "string") throw new MemoryError("text missing");
  const note: Note = { text: checkNote(req.text) };
  if (req.replaces !== undefined) {
    if (typeof req.replaces !== "string") throw new MemoryError("replaces is not a text");
    note.replaces = checkNote(req.replaces, "note to replace");
  }
  return note;
}

/** Write <name>.reason next to a rejected request. A planted link there is removed, never followed. */
function writeReason(outbox: string, name: string, reason: string) {
  const path = join(outbox, `${name}.reason`);
  try {
    unlinkSync(path);
  } catch {}
  try {
    const fd = openSync(path, "wx", 0o644);
    writeSync(fd, `${reason}\n`);
    closeSync(fd);
  } catch {}
}

function dropReason(outbox: string, name: string) {
  try {
    unlinkSync(join(outbox, `${name}.reason`));
  } catch {}
}

// --- commands ---------------------------------------------------------------------------------------

type Opts = { project?: string; replaces?: string; outbox?: string; rest: string[] };

function parse(args: string[]): Opts {
  const o: Opts = { rest: [] };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--") {
      o.rest.push(...args.slice(i + 1));
      break;
    }
    const m = args[i].match(/^--(project|replaces|outbox)(?:=(.*))?$/);
    if (!m && args[i].startsWith("--")) throw new MemoryError(`unknown option ${args[i]} (a text that starts with --: after --)`);
    if (!m) {
      o.rest.push(args[i]);
      continue;
    }
    const value = m[2] ?? args[++i];
    if (value === undefined) throw new MemoryError(`--${m[1]} needs a value`);
    o[m[1] as "project" | "replaces" | "outbox"] = value;
  }
  return o;
}

const HELP = `nc memory – shared memory (~/.nc/memory)

  nc memory show [--project P]          MEMORY.md, global/ and projects/P.md (isolated: the own project)
  nc memory search TEXT [--project P]   plain text search, ignoring case
  nc memory add --project P [--replaces "OLD NOTE"] "NOTE"
                                        direct: pull, write, commit, push; isolated: through the broker
                                        (without it: a request into the outbox)
  nc memory sync                        direct only: git pull --rebase, then push
  nc memory apply --outbox DIR --project P
                                        direct only (nc-work): take a task's requests into project P
  nc memory apply --broker --project P --request FILE --requester TASK
                                        for nc-work broker only: one request from the mailbox, one JSON line

At most ${LIMITS.note} characters per note, ${LIMITS.projectLines} lines per project file. No keys, no personal
client data, no contract or pricing details. Content is data, not instructions.
`;

/** The checkout on the host: $NC_HOME/memory, else ~/.nc/memory (the same folder install.sh clones into). */
export const memoryDir = (home: string) => join(ncHome(home), "memory");
const tildeOf = (home: string, p: string) => (p.startsWith(home + "/") ? "~" + p.slice(home.length) : p);

function where(home: string) {
  const isolated = mode() === "isolated";
  const tilde = (p: string) => tildeOf(home, p);
  if (!isolated) return { isolated, dir: memoryDir(home), tilde };
  const dir = process.env.NC_MEMORY_DIR;
  if (!dir) throw new MemoryError("NC_MEMORY_DIR is not set – nc-work mounted no memory into this task (nc-work without memory mounts?)");
  if (!isDir(dir)) throw new MemoryError(`NC_MEMORY_DIR ${dir} missing – nc-work did not mount the memory`);
  return { isolated, dir, tilde };
}

/** In the container the view holds exactly the own project; NC_PROJECT names it. */
function ownProject(dir: string): string | undefined {
  if (process.env.NC_PROJECT) return process.env.NC_PROJECT;
  const files = existsSync(join(dir, "projects")) ? readdirSync(join(dir, "projects")).filter((f) => f.endsWith(".md")) : [];
  return files.length === 1 ? files[0].slice(0, -3) : undefined;
}

function show(home: string, o: Opts): number {
  const { isolated, dir, tilde } = where(home);
  const index = join(dir, "MEMORY.md");
  if (!isFile(index)) throw new MemoryError(`${tilde(index)} missing${isolated ? "" : " – ./install.sh or nc memory sync"}`);
  const files = ["MEMORY.md", ...mdFiles(dir, "global")];
  if (o.project) files.push(relative(dir, projectFile(dir, o.project)));
  const own = !o.project && isolated ? ownProject(dir) : undefined;
  if (own && isFile(join(dir, "projects", `${own}.md`))) files.push(`projects/${own}.md`);
  const project = o.project ?? own;
  const parts = files.map((f) => `=== ${f} ===\n${readFileSync(join(dir, f), "utf8").trimEnd()}\n`);
  process.stdout.write(parts.join("\n"));
  if (!project && !isolated) process.stdout.write("\n(project knowledge: nc memory show --project <project>)\n");
  return 0;
}

function search(home: string, o: Opts): number {
  const { dir } = where(home);
  const query = o.rest.join(" ").trim().toLowerCase();
  if (!query) throw new MemoryError("search text missing: nc memory search TEXT");
  let files = mdFiles(dir);
  if (o.project) {
    const own = relative(dir, projectFile(dir, o.project));
    files = files.filter((f) => f === "MEMORY.md" || f.startsWith("global/") || f === own);
  }
  let hits = 0;
  for (const f of files) {
    readFileSync(join(dir, f), "utf8").split("\n").forEach((line, i) => {
      if (!line.toLowerCase().includes(query)) return;
      console.log(`${f}:${i + 1}: ${line}`);
      hits++;
    });
  }
  if (!hits) {
    process.stderr.write(`no matches for "${query}"\n`);
    return 1;
  }
  return 0;
}

/**
 * nc memory add in a task with a mailbox: the note as a memory request to the broker, which applies it on the host. Null
 * means fall back to the outbox – only when the request never reached the broker: no mailbox
 * (a task made by an older nc-work), a heartbeat that is old before posting, or a request the client took back (TakenBack, after
 * a stale heartbeat or its own waiting time). The broker calls the harness only for a request it deleted from the mailbox
 * itself, so a note taken back is never applied twice. Picked up but no answer in time: exit 2, no fallback.
 */
function throughBroker(note: Note, own: string | undefined): number | null {
  if (!process.env.NC_REQUESTS || !process.env.NC_INBOX) return null;
  let m: Mailbox;
  try {
    m = mailbox();
  } catch {
    return null;
  }
  if (!brokerAlive(m)) return null;
  let name: string;
  try {
    name = post(m, "m", { v: 1, type: "memory", text: note.text, ...(note.replaces !== undefined ? { replaces: note.replaces } : {}) });
  } catch {
    return null;  // not in the mailbox, so the broker never saw it
  }
  let r;
  try {
    r = awaitAnswer(m, name, ["stored", "refused", "error"], answerMs("memory"));
  } catch (e) {
    if (e instanceof TakenBack) return null;
    if (e instanceof Refused) throw e;  // dropped by the host (.dropped): exit 1, no fallback
    if (e instanceof DelegateError)
      throw new DelegateError(`note is still being processed – do not submit it again, the result shows in the broker's pane (${e.message})`);
    throw e;
  }
  if (r.state === "refused") throw new Refused(reasonOf(r));
  if (r.state !== "stored") throw new DelegateError(reasonOf(r));
  const res = r.result as any;
  const raw = res?.outcome;
  const outcome = OUTCOMES.includes(raw) ? raw : "stored";  // an outcome this client does not know still means stored
  console.log(`projects/${own ?? "?"}.md: ${outcome}`);
  if (res?.pushed !== true) console.log("stored locally, push later (nc memory sync on the host)");
  return 0;
}

function add(home: string, o: Opts): number {
  const { isolated, dir, tilde } = where(home);
  const note: Note = { text: checkNote(o.rest.join(" ")) };
  if (o.replaces !== undefined) note.replaces = checkNote(o.replaces, "note to replace");

  if (isolated) {
    const own = process.env.NC_PROJECT;
    if (o.project !== undefined) {
      if (!PROJECT.test(o.project)) throw new MemoryError(`invalid project name: ${o.project}`);
      if (own && o.project !== own) throw new MemoryError(`this task belongs to project ${own}; notes for ${o.project} cannot go from here`);
    }
    const viaBroker = throughBroker(note, own ?? ownProject(dir));
    if (viaBroker !== null) return viaBroker;
    const outbox = process.env.NC_MEMORY_OUTBOX;
    if (!outbox) throw new MemoryError("NC_MEMORY_OUTBOX is not set – nc-work mounted no outbox into this task (nc-work without memory mounts?)");
    if (!isDir(outbox)) throw new MemoryError(`NC_MEMORY_OUTBOX ${outbox} missing – nc-work did not mount the outbox`);
    const ts = new Date().toISOString();
    const name = `${ts.replace(/[-:.]/g, "")}-${randomBytes(4).toString("hex")}.json`;
    const request = { v: 1, ts, text: note.text, ...(note.replaces !== undefined ? { replaces: note.replaces } : {}) };
    const tmp = join(outbox, `.${name}.tmp`);
    writeFileSync(tmp, JSON.stringify(request) + "\n", { flag: "wx", mode: 0o644 });
    renameSync(tmp, join(outbox, name));
    if (process.env.NC_REQUESTS && process.env.NC_INBOX) console.log("broker not reachable – note in the outbox, later nc-work memory-apply");
    console.log(`request ${name} in the outbox. It reaches the memory only when the host transfers it (nc-work memory-apply).`);
    return 0;
  }

  if (!o.project) throw new MemoryError("--project missing – a note without a project is not written");
  if (!PROJECT.test(o.project)) throw new MemoryError(`invalid project name: ${o.project}`);
  readyToWrite(dir, tilde(dir));
  pull(dir);
  const file = projectFile(dir, o.project);
  const text = readFileSync(file, "utf8");
  const lines = splitLines(text);
  const outcome = applyNote(lines, note, today());
  if (outcome === "unchanged") {
    console.log(`projects/${o.project}.md: already there, unchanged`);
    return 0;
  }
  writeFileSync(file, lines.join("\n") + "\n");
  const pushed = commitAndPush(dir, file, `nc memory add: ${o.project} (${outcome})`);
  console.log(`projects/${o.project}.md: ${outcome}`);
  if (!pushed) throw new MemoryError(`note is ${PUSH_FAILED}`);
  return 0;
}

function sync(home: string): number {
  const { isolated, dir, tilde } = where(home);
  if (isolated) throw new MemoryError("sync exists only direct on the host; in a task the memory is a read-only copy");
  readyToWrite(dir, tilde(dir));
  pull(dir);
  const ahead = git(dir, ["rev-list", "--count", "@{u}..HEAD"]);
  if (ahead.ok && ahead.out !== "0" && !git(dir, ["push", "-q", "origin", "HEAD"]).ok)
    throw new MemoryError(`${ahead.out} local commit(s), push failed`);
  console.log(`${tilde(dir)} up to date (${git(dir, ["rev-parse", "--short", "HEAD"]).out})`);
  return 0;
}

/** Called by nc-work on the host for one task: --project comes from nc-work's records, never from a request. */
function apply(home: string, o: Opts): number {
  const { isolated, dir, tilde } = where(home);
  if (isolated) throw new MemoryError("apply exists only on the host (nc-work memory-apply)");
  if (!o.outbox || !o.project) throw new MemoryError("nc memory apply --outbox DIR --project P");
  if (!PROJECT.test(o.project)) throw new MemoryError(`invalid project name: ${o.project}`);
  if (!isDir(o.outbox)) throw new MemoryError(`outbox ${o.outbox} missing or not a folder`);
  // The same entries nc-work counts as pending: every *.json not starting with a dot. Odd names are rejected, not skipped.
  const all = readdirSync(o.outbox).filter((n) => n.endsWith(".json") && !n.startsWith(".")).sort();
  const entries = all.slice(0, LIMITS.requestsPerRun);  // the rest waits for the next run: reported, not rejected
  const later = all.length - entries.length;
  const names = entries.filter((n) => REQUEST_NAME.test(n));
  const rejected: [string, string][] = entries.filter((n) => !REQUEST_NAME.test(n)).map((n) => [n, "file name is not a valid request name (A-Z, a-z, 0-9, . _ -)"]);
  if (!entries.length) {
    console.log(`${o.project}: no requests`);
    return 0;
  }

  const done: string[] = [];
  const report: string[] = [];  // one line per applied request: shown to the human and kept in the commit body
  const count: Record<Outcome, number> = { new: 0, refreshed: 0, replaced: 0, unchanged: 0 };
  let error: string | null = null;
  let unwritten = false;
  let unchanged = false;
  if (names.length) {
    readyToWrite(dir, tilde(dir));
    pull(dir);
    const file = projectFile(dir, o.project);
    const before = readFileSync(file, "utf8");
    const lines = splitLines(before);
    const date = today();
    for (const name of names) {
      try {
        const note = readRequest(join(o.outbox, name));
        const outcome = applyNote(lines, note, date, true);
        count[outcome]++;
        done.push(name);
        report.push(`${outcome}: ${note.replaces !== undefined ? `"${note.replaces}" → "${note.text}"` : `"${note.text}"`}`);
      } catch (e) {
        if (!(e instanceof MemoryError)) throw e;
        rejected.push([name, e.message]);
      }
    }
    // Decided by the file, not the counters: requests that cancel out (A → B, B → A) leave nothing to commit and are done.
    const after = lines.join("\n") + "\n";
    unchanged = after === before;
    if (count.new + count.refreshed + count.replaced && !unchanged) {
      writeFileSync(file, after);
      const message = `nc memory apply: ${o.project} (${done.length} request(s))\n\n${report.join("\n")}\n`;
      try {
        // Not pushed: the notes are safe in a local commit, so the requests count as done anyway.
        if (!commitAndPush(dir, file, message)) error = `notes are ${PUSH_FAILED}`;
      } catch (e) {
        if (!(e instanceof MemoryError)) throw e;
        error = `${e.message}; the requests stay in the outbox`;
        done.length = 0;
        unwritten = true;
      }
    }
  }
  for (const name of done) {
    try {
      unlinkSync(join(o.outbox, name));  // the container may have removed it meanwhile
    } catch {}
    dropReason(o.outbox, name);
  }
  for (const [name, reason] of rejected) writeReason(o.outbox, name, visible(reason));

  const summary = (Object.keys(count) as Outcome[]).filter((k) => count[k]).map((k) => `${count[k]} ${k}`);
  console.log(`projects/${o.project}.md: ${summary.join(", ") || "nothing taken over"}${rejected.length ? `, ${rejected.length} refused` : ""}${unwritten ? " – not written" : ""}${unchanged && count.replaced + count.new + count.refreshed ? " – the file is the same in the end, no commit" : ""}`);
  for (const line of report) console.log(`  ${line}`);
  for (const [name, reason] of rejected) {
    const shown = REQUEST_NAME.test(name) ? name : visible(JSON.stringify(name));
    process.stderr.write(`  refused ${shown}: ${visible(reason)} (stays in the outbox with a .reason)\n`);
  }
  if (later) console.log(`  ${later} more request(s) stay in the outbox (at most ${LIMITS.requestsPerRun} per run) – nc-work memory-apply again`);
  if (error) process.stderr.write(`nc memory: ${error}\n`);
  return rejected.length || error ? 1 : 0;
}

// --- lock on ~/.nc/memory -------------------------------------------------------------------------------------

/** flock(1) exit when the lock was not got in time. */
const LOCK_BUSY = 75;
/** Seconds to wait for the lock: 120, as the broker's caller 60 (budget below); NC_MEMORY_LOCK_S for tests. */
function lockSeconds(broker: boolean): number {
  const s = Number(process.env.NC_MEMORY_LOCK_S);
  return Number.isFinite(s) && s > 0 ? s : broker ? 60 : 120;
}

type Locked = { code: number; out?: string } | { busy: true } | { signal: string } | { noFlock: true };

/**
 * bin/nc memory ARGS again, under `flock -x` on the folder ~/.nc/memory itself, with NC_MEMORY_LOCKED=1. The folder, not a
 * file in it: a lock file would make `git status` dirty, and readyToWrite would refuse every note. The caller checks that the
 * folder exists (flock would create a file there). stderr is the child's; so is stdout, unless `capture` (apply --broker):
 * then it comes back in `out` for the caller to pass on. `extra` goes into the child's environment.
 */
function underLock(repo: string, dir: string, args: string[], seconds: number, extra: Record<string, string> = {}, capture = false): Locked {
  const flock = Bun.which("flock");
  if (!flock) return { noFlock: true };
  const r = Bun.spawnSync([flock, "-x", "-w", String(seconds), "-E", String(LOCK_BUSY), dir, join(repo, "bin/nc"), "memory", ...args], {
    cwd: "/", stdio: ["ignore", capture ? "pipe" : "inherit", "inherit"], env: { ...process.env, ...extra, NC_MEMORY_LOCKED: "1" },
  });
  if (r.exitCode === null) return { signal: r.signalCode ?? "a signal" };
  if (r.exitCode === LOCK_BUSY) return { busy: true };
  return capture ? { code: r.exitCode, out: r.stdout?.toString() ?? "" } : { code: r.exitCode };
}

/** add (direct), sync, apply --outbox: under the lock if there is a folder to lock. Without flock: a warning, then on without it. */
function withLock(repo: string, home: string, args: string[], run: () => number): number {
  const dir = memoryDir(home);
  if (process.env.NC_MEMORY_LOCKED === "1" || !isDir(dir)) return run();  // no folder: readyToWrite says what is missing
  const seconds = lockSeconds(false);
  const r = underLock(repo, dir, args, seconds);
  if ("noFlock" in r) {
    process.stderr.write(`nc memory: warning: flock not found (util-linux) – without a lock on ${tildeOf(home, dir)}\n`);
    return run();
  }
  if ("busy" in r) throw new MemoryError(`${tildeOf(home, dir)} has been locked for ${seconds} s (another nc memory is writing) – try again later`);
  if ("signal" in r) throw new MemoryError(`stopped by ${r.signal} – check ${tildeOf(home, dir)} (git status)`);
  return r.code;
}

// --- apply --broker: one memory request from a task's mailbox (nc-work broker) ---------------------------------

/** Exit 2 in --broker mode: the host's fault (checkout, git, lock, arguments), never the request's. */
class InfraError extends Error {}
class Expired extends InfraError {}

/**
 * Time budget. nc-work broker kills the call's process group after 300 s, and every git() has 60 s. From the start of the
 * outer process (the one nc-work started; it hands its start to the child under the lock in NC_MEMORY_START), lock wait
 * (60 s) included, no new git call starts after 220 s: before the commit that is an error, after it stored with pushed:false.
 * So the last git call ends after 280 s at the latest. NC_MEMORY_BUDGET_S shortens the 220 s for tests.
 */
const BUDGET_S = 220;
function budgetEnd(start: number): number {
  const s = Number(process.env.NC_MEMORY_BUDGET_S);
  return start + (Number.isFinite(s) && s > 0 ? s : BUDGET_S) * 1000;
}

type BrokerArgs = { project: string; request: string; requester: string };

/** Exactly --broker (no value) and --project, --request, --requester (each once, a value each). */
function brokerArgs(args: string[]): BrokerArgs {
  const seen = new Set<string>();
  const o: Record<string, string> = {};
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (seen.has(a)) throw new InfraError(`${visible(a).slice(0, 40)} given twice`);
    if (a === "--broker") {
      seen.add(a);
      continue;
    }
    if (a !== "--project" && a !== "--request" && a !== "--requester")
      throw new InfraError(`apply --broker takes only --project, --request and --requester (not ${visible(JSON.stringify(a)).slice(0, 40)})`);
    const value = args[++i];
    if (value === undefined) throw new InfraError(`${a} needs a value`);
    seen.add(a);
    o[a.slice(2)] = value;
  }
  for (const k of ["project", "request", "requester"]) if (o[k] === undefined) throw new InfraError(`apply --broker needs --${k}`);
  if (!PROJECT.test(o.project)) throw new InfraError(`--project ${visible(JSON.stringify(o.project)).slice(0, 60)}: not a project name`);
  if (!PROJECT.test(o.requester)) throw new InfraError(`--requester ${visible(JSON.stringify(o.requester)).slice(0, 60)}: not a task name`);
  return o as BrokerArgs;
}

/** The request (the broker's staged copy): read like every request, then exactly {v:1, type:"memory", text, replaces?}. Refused (exit 1) for anything else. */
function brokerRequest(path: string): Note {
  let req: Record<string, unknown>;
  try {
    req = parseObject(readBounded(path, LIMITS.requestBytes));
    if ("project" in req) throw new MemoryError("contains a project field – the host sets the project, not the request");
    rejectUnknown(req, BROKER_KEYS);
  } catch (e) {
    if (e instanceof RequestError) throw new MemoryError(e.message);
    throw e;
  }
  if (req.v !== 1) throw new MemoryError(`version ${String(JSON.stringify(req.v)).slice(0, 40)} unknown, expected 1`);
  if (req.type !== "memory") throw new MemoryError(`type ${String(JSON.stringify(req.type)).slice(0, 40)} unknown, expected memory`);
  if (typeof req.text !== "string") throw new MemoryError("text missing");
  const note: Note = { text: checkNote(req.text) };
  if (req.replaces !== undefined) {
    if (typeof req.replaces !== "string") throw new MemoryError("replaces is not a text");
    note.replaces = checkNote(req.replaces, "note to replace");
  }
  return note;
}

type BrokerLine =
  | { state: "stored"; outcome: Outcome; pushed: boolean; note: string }
  | { state: "refused"; reason: string }
  | { state: "error"; reason: string };

/** Under the lock: pull, apply the note to projects/<project>.md only, commit and push. Phases decide refused or error. */
function brokerApplyLocked(home: string, a: BrokerArgs, note: Note, end: number): BrokerLine {
  const dir = memoryDir(home);
  const tilde = tildeOf(home, dir);
  const check = () => {
    if (Date.now() >= end) throw new Expired("deadline passed (lock or git too slow), nothing written");
  };
  const infra = (f: () => void) => {
    try {
      f();
    } catch (e) {
      if (e instanceof MemoryError) throw new InfraError(e.message);
      throw e;
    }
  };
  infra(() => readyToWrite(dir, tilde, check));
  infra(() => pull(dir, check));
  const file = projectFile(dir, a.project);  // MemoryError: refused (no such project file)
  const before = readFileSync(file, "utf8");
  const lines = splitLines(before);
  const outcome = applyNote(lines, note, today(), true);  // MemoryError: refused (deletion, no note to replace, 100 lines)
  const shown = [...note.text].slice(0, 120).join("");
  if (outcome === "unchanged") {
    if (Date.now() >= end) return { state: "stored", outcome, pushed: false, note: shown };  // past the budget: no rev-list
    const ahead = git(dir, ["rev-list", "--count", "@{u}..HEAD"]);
    return { state: "stored", outcome, pushed: ahead.ok && ahead.out === "0", note: shown };
  }
  check();
  writeFileSync(file, lines.join("\n") + "\n");
  const body = `${outcome}: ${note.replaces !== undefined ? `"${note.replaces}" → "${note.text}"` : `"${note.text}"`}`;
  let pushed = false;
  infra(() => {
    pushed = commitAndPush(dir, file, `nc memory apply: ${a.project} (task ${a.requester}, ${outcome})\n\n${body}\n`, () => Date.now() < end);
  });
  return { state: "stored", outcome, pushed, note: shown };
}

function brokerLine(a: () => BrokerLine | number): number {
  let line: BrokerLine;
  try {
    const r = a();
    if (typeof r === "number") return r;  // the child under the lock wrote the line
    line = r;
  } catch (e: any) {
    const reason = (text: string) => visible(text).slice(0, REASON_CHARS);
    if (e instanceof MemoryError) line = { state: "refused", reason: reason(e.message) };
    else if (e instanceof InfraError) line = { state: "error", reason: reason(e.message) };
    else line = { state: "error", reason: reason(`unexpected error: ${e?.message ?? e}`) };
  }
  process.stdout.write(JSON.stringify(line) + "\n");
  return line.state === "stored" ? 0 : line.state === "refused" ? 1 : 2;
}

/**
 * nc memory apply --broker: exactly one JSON line on stdout, exit 0 stored, 1 refused, 2 error – also for a crash (Bun would
 * end with exit 1, which would read as refused). Project and requester come from nc-work's record of the task, the request
 * file is the broker's staged copy. The outer process checks arguments and request, then re-runs itself under the lock and
 * takes the child's stdout. It passes the child's line on only if the child ended with 0, 1 or 2 and wrote something; otherwise
 * it writes its own error line: flock exit 75, flock missing (no isolation on the Mac), flock killed by a signal, and a child that died
 * without its line – flock(1) reports a child killed by a signal (OOM killer, crash) as exit 128+n, and Bun crashing before
 * the line ends with 1. A line the child wrote before dying with another code is dropped, so there is always exactly one.
 */
function brokerApply(repo: string, home: string, args: string[]): number {
  return brokerLine(() => {
    const locked = process.env.NC_MEMORY_LOCKED === "1";
    const startEnv = Number(process.env.NC_MEMORY_START);
    const start = locked && Number.isFinite(startEnv) && startEnv > 0 ? startEnv : Date.now();
    const a = brokerArgs(args);
    if (mode() === "isolated") throw new InfraError("apply --broker exists only on the host (nc-work broker)");
    const note = brokerRequest(a.request);
    const dir = memoryDir(home);
    if (locked) {
      // tests/memory.sh: a child that dies under the lock without writing its line
      if (process.env.NC_MEMORY_TEST_DIE === "kill") process.kill(process.pid, "SIGKILL");
      if (process.env.NC_MEMORY_TEST_DIE === "exit1") process.exit(1);
      return brokerApplyLocked(home, a, note, budgetEnd(start));
    }
    if (!isDir(dir)) throw new InfraError(`${tildeOf(home, dir)} missing or not a folder – ./install.sh`);
    const seconds = lockSeconds(true);
    const r = underLock(repo, dir, ["apply", ...args], seconds, { NC_MEMORY_START: String(start) }, true);
    if ("noFlock" in r) throw new InfraError("flock not found (util-linux) – apply --broker does not write without a lock");
    if ("busy" in r) throw new InfraError(`${tildeOf(home, dir)} has been locked for ${seconds} s (another nc memory is writing) – submit the note again`);
    if ("signal" in r) throw new InfraError(`stopped by ${r.signal} – check ${tildeOf(home, dir)} (git status)`);
    const out = r.out ?? "";
    if (![0, 1, 2].includes(r.code) || !out.trim()) throw new InfraError(`stopped (exit ${r.code}) – check ${tildeOf(home, dir)} (git status)`);
    process.stdout.write(out);
    return r.code;
  });
}

export function memory(repo: string, home: string, args: string[]): number {
  const [sub, ...rest] = args;
  // Before parse, and only for apply: a note text "--broker" given to add triggers nothing.
  if (sub === "apply" && rest.includes("--broker")) return brokerApply(repo, home, rest);
  try {
    const o = parse(rest);
    switch (sub) {
      case "show":
        return show(home, o);
      case "search":
        return search(home, o);
      case "add":
        return mode() === "isolated" ? add(home, o) : withLock(repo, home, args, () => add(home, o));
      case "sync":
        return withLock(repo, home, args, () => sync(home));
      case "apply":
        return withLock(repo, home, args, () => apply(home, o));
      case undefined:
      case "help":
      case "-h":
      case "--help":
        process.stdout.write(HELP);
        return 0;
      default:
        process.stderr.write(`nc memory: unknown command: ${sub}\n\n${HELP}`);
        return 2;
    }
  } catch (e) {
    // MemoryError and Refused (the broker said no, or dropped the request): exit 1; DelegateError (mailbox, broker): exit 2.
    if (!(e instanceof MemoryError || e instanceof Refused || e instanceof DelegateError)) throw e;
    process.stderr.write(`nc memory: ${e.message}\n`);
    return e instanceof DelegateError ? 2 : 1;
  }
}

// --- nc doctor ---------------------------------------------------------------------------------------

type Check = { name: string; status: "ok" | "warn" | "fail"; detail: string };

/** Direct: the checkout in ~/.nc/memory is there, has a remote, is clean and within the limits. */
export function memoryChecksDirect(home: string): Check[] {
  const dir = memoryDir(home);
  const name = tildeOf(home, dir);
  // Memory is optional (no default remote): only a checkout that is there but broken fails.
  if (!lstatSync(dir, { throwIfNoEntry: false }))
    return [{ name, status: "warn", detail: "none – set NC_MEMORY_REMOTE to your copy of nc-memory-template, then ./install.sh" }];
  if (!isDir(join(dir, ".git"))) return [{ name, status: "fail", detail: "not a git checkout" }];
  const checks: Check[] = [];
  checks.push(
    git(dir, ["remote", "get-url", "origin"]).ok
      ? { name, status: "ok", detail: "git checkout with remote origin" }
      : { name, status: "fail", detail: "no remote origin – nc memory add cannot push" },
  );
  checks.push(
    git(dir, ["status", "--porcelain"]).out
      ? { name: "memory clean", status: "warn", detail: "uncommitted changes – nc memory add refuses until they are committed or discarded" }
      : { name: "memory clean", status: "ok", detail: "no uncommitted changes" },
  );
  checks.push(...limitChecks(dir));
  return checks;
}

function limitChecks(dir: string): Check[] {
  const checks: Check[] = [];
  const index = join(dir, "MEMORY.md");
  if (!isFile(index)) checks.push({ name: "MEMORY.md", status: "fail", detail: "missing" });
  else {
    const n = lineCount(readFileSync(index, "utf8"));
    checks.push(
      n <= LIMITS.indexLines
        ? { name: "MEMORY.md", status: "ok", detail: `${n} lines (at most ${LIMITS.indexLines})` }
        : { name: "MEMORY.md", status: "fail", detail: `${n} lines, at most ${LIMITS.indexLines}` },
    );
  }
  for (const f of mdFiles(dir, "projects")) {
    const n = lineCount(readFileSync(join(dir, f), "utf8"));
    if (n > LIMITS.projectLines) checks.push({ name: f, status: "fail", detail: `${n} lines, at most ${LIMITS.projectLines}` });
  }
  return checks;
}

/** Try to create a file in dir. True if that worked (the probe is removed again). */
function canWrite(dir: string): boolean {
  const probe = join(dir, `.nc-doctor-${process.pid}.tmp`);
  try {
    closeSync(openSync(probe, "wx", 0o600));
  } catch {
    return false;
  }
  try {
    unlinkSync(probe);
  } catch {}
  return true;
}

/** Isolated: the view is really read-only and holds only the own project, the outbox is writable. */
export function memoryChecksIsolated(): Check[] {
  const checks: Check[] = [];
  const dir = process.env.NC_MEMORY_DIR;
  const outbox = process.env.NC_MEMORY_OUTBOX;
  const hint = "nc-work mounted no memory (nc-work without memory mounts?)";
  if (!dir) checks.push({ name: "NC_MEMORY_DIR", status: "fail", detail: `not set – ${hint}` });
  else if (!isDir(dir)) checks.push({ name: "NC_MEMORY_DIR", status: "fail", detail: `${dir} missing` });
  else {
    checks.push(
      canWrite(dir)
        ? { name: "NC_MEMORY_DIR", status: "fail", detail: `${dir} is writable – nc-work must mount it read-only` }
        : { name: "NC_MEMORY_DIR", status: "ok", detail: `${dir}, read-only` },
    );
    const own = process.env.NC_PROJECT;
    const projects = isDir(join(dir, "projects")) ? readdirSync(join(dir, "projects")) : [];
    const foreign = projects.filter((f) => (own ? f !== `${own}.md` : projects.length > 1));
    if (existsSync(join(dir, "journal"))) foreign.push("journal/");
    checks.push(
      foreign.length
        ? { name: "other projects", status: "fail", detail: `visible: ${foreign.slice(0, 5).join(", ")}` }
        : { name: "other projects", status: "ok", detail: own ? `only projects/${own}.md` : "none" },
    );
    checks.push(...limitChecks(dir).filter((c) => c.status !== "ok" || c.name === "MEMORY.md"));
  }
  if (!outbox) checks.push({ name: "NC_MEMORY_OUTBOX", status: "fail", detail: `not set – ${hint}` });
  else
    checks.push(
      isDir(outbox) && canWrite(outbox)
        ? { name: "NC_MEMORY_OUTBOX", status: "ok", detail: `${outbox}, writable` }
        : { name: "NC_MEMORY_OUTBOX", status: "fail", detail: `${outbox} missing or not writable` },
    );
  return checks;
}

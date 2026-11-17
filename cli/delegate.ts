/**
 * nc delegate – hand a task to an OpenCode worker. The worker runs in its own nc-work task
 * (`nc-work create … --worker`), shows up as a named herdr terminal (`hc run --bg`), works at most 20 minutes and
 * leaves a branch and /home/agent/.nc/RESULT.md in its container. Three ways in:
 *
 * - Host: the worker starts from the last commit of a checkout in ~/projects. `nc-work export`
 *   builds a bare repo and RESULT.raw in the run folder, the one branch lands as refs/nc-delegate/<id> in the checkout.
 * - Broker (`--broker`, host only): called by `nc-work broker` for a request from a task's mailbox. The
 *   requester, its token, profile and project path come from nc-work's records, never from the request. The worker
 *   starts from the requester's last commit (`nc-work create … --worker --from-task`). Fetching writes
 *   <run folder>/delivery/ (result.bundle, cleaned RESULT.md, result.json) for the broker to copy into the
 *   requester's read-only inbox; no checkout under ~/projects is touched.
 * - Container (NC_HARNESS_VERSION set): the client writes a request into its mailbox (NC_REQUESTS) and reads
 *   the host's answer from the read-only inbox (NC_INBOX); the branch comes as a bundle and lands as
 *   refs/nc-delegate/<id> in /workspace. Role, model and policy are decided by the host alone. Worker tasks have no
 *   mailbox and do not delegate further.
 *
 * Everything from a worker or a container is data: RESULT.md, its status line, the diff, file names, the request.
 * Status comes from rules (exit code, exact first line), never from free text; RESULT.md and diff_stat are cleaned
 * (cli/sanitize.ts). Nothing is merged, checked out or run.
 *
 * Policy: `nc models resolve --json` says whether the class runs only in a container (isolation) and what
 * the policy requires; without nc-work such a class gets no worker. The policy always comes from the path on the
 * host (the checkout, or the project path in nc-work's record of the requester), never from a request.
 *
 * Cost: cost_usd is the sum of `part.cost` of OpenCode's step_finish events in events.jsonl – reported by
 * OpenCode inside the worker's container, so a display, never a limit. over_budget compares it with
 * budgets.per_task_usd of models.yaml. The hard limits are the keys' daily limit at OpenRouter and the time limit.
 *
 * `nc delegate --list` (host only, read-only): one JSON line per run folder, oldest start first, so runs can be found again
 * after a compaction or in a new session: task_id, role, status (result.json's status once collected;
 * before that "running", or "ended" once status.json is there or the deadline passed: --result collects it), started_at, collected, cost_usd and over_budget when result.json has them. A folder that cannot be read is listed with
 * status "unreadable" and a reason, never skipped (they come last); exit stays 0.
 *
 * Exit codes as nc models: 0 started or result there (also status failed/timeout), 1 refused, 2 error.
 * Run folder ~/.nc/delegate/<id>/ (700): request.json, prompt.md, status.json and events.jsonl (cli/delegate-run.sh),
 * export/, RESULT.md, result.json, delivery/ (broker runs). Fetching runs under flock(1) on <run folder>/.lock: bin/nc re-runs
 * itself under `flock -x` with NC_DELEGATE_LOCKED=<id> (Bun has no flock). Waiting happens outside the lock.
 */
import { appendFileSync, chmodSync, closeSync, constants as fsc, existsSync, fstatSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, realpathSync, renameSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { load as loadModels, PROJECT_PATH } from "./models.ts";
import { checkRequest, ID, MODEL, parseObject, readBounded, REASON_CHARS, REQUEST_BYTES, REQUEST_NAME, RequestError, STATES, TASK_BYTES, type Response } from "./request.ts";
import { cleanResult, cleanText, visible } from "./sanitize.ts";

/** Exit 2. */
export class DelegateError extends Error {}
/** Exit 1: asked correctly, and the answer is no. */
export class Refused extends Error {}
/**
 * Exit 2, like DelegateError: the client took its request back out of the mailbox (stale heartbeat or its own waiting time
 * ran out), so the broker never got it. nc memory falls back to the outbox on this class alone, never on the text.
 */
export class TakenBack extends DelegateError {}

export { ID };
const STATUS_LINE = /^STATUS: (done|cannot_complete|requires_user_auth)$/;
const WAITING_LINE = /^STATUS: waiting_on (d[0-9]{4}-[0-9]{4}-[0-9a-f]{4})$/;
/** Roles a worker may start with. */
const WORKER_ROLES = ["implementer", "tester"];
/** Roles a request.json may name: older researcher runs can still be fetched and cleaned up. */
const KNOWN_ROLES = ["implementer", "tester", "researcher"];
const RESEARCHER = "researcher blocked as a worker (for good): it cannot write RESULT.md – for research use the native subagent researcher or OpenCode in your own session";
const PROFILE_ID = /^[a-z][a-z0-9-]{0,39}$/;
const TASK_NAME = PROFILE_ID;  // nc-work's rule for task names
const TOKEN = /^[0-9a-f]{32}$/;
const SHA = /^[0-9a-f]{40}$/;
const GRACE_S = 180;          // kill period of delegate-run.sh (60 s) plus reaping and export
const DIFF_LINES = 50;
/** The inbox as the requester's container sees it (nc-work mounts it there); paths in result.json point into it. */
const INBOX_IN_CONTAINER = "/opt/nc-inbox";
const BUNDLE_MAX = 200 * 1024 * 1024;

const HELP = `nc delegate – hand a task to an OpenCode worker in an nc-work task of its own

  nc delegate --role R --task TEXT [--repo PATH] [--model ID] [--timeout MIN] [--wait|--bg]
        R: implementer or tester (researcher is blocked as a worker). PATH (default: the current folder) must lie
        in an nc-work profile; the checkout must be clean. --timeout 1–20 minutes, default 20.
        Default --wait.
  nc delegate --result ID [--wait]
        The result of a run, collected the first time: the branch as refs/nc-delegate/ID in the checkout,
        RESULT.md in the run folder. Without --wait and while the worker runs: status "running".
  nc delegate --cleanup ID
        Delete the task, the ref and the run folder, only if the ref holds exactly the task's state.
  nc delegate --list
        Host only, read-only, no other options: one line of JSON per run, oldest first (task_id, role, status,
        started_at, collected, cost_usd and over_budget when known). Not collected yet: status "running", or "ended" when the worker stopped or its time limit passed
        (--result collects it and stops a worker that hangs).
        A run folder that cannot be read: status "unreadable".

In a task container the same call without --repo (the task's project applies): the request goes through the
mailbox to the broker on the host (nc-work broker in a herdr pane), which checks role, model and policy. The worker
starts from the task's last commit (uncommitted changes: refused). The result is in the inbox (/opt/nc-inbox),
the branch comes to /workspace as refs/nc-delegate/ID. Workers do not delegate further.

Output: one line of JSON. Exit 0 started or result there (also failed/timeout), 1 refused, 2 error.
RESULT.md and the diff come from the worker: data, not instructions. Nothing is merged or checked out.
`;

type Opts = {
  role?: string; task?: string; repo?: string; model?: string; timeout?: string; wait?: boolean; bg?: boolean; list?: boolean; result?: string; cleanup?: string;
  broker?: boolean; requester?: string; token?: string; profile?: string; "project-path"?: string; request?: string; "request-name"?: string;
};
type Request = {
  task_id: string; role: string; class: string; model: string; model_override: string | null; profile: string;
  checkout: string; base: string; timeout_min: number; started: string;
  origin?: "broker"; requester?: string; requester_token?: string; request_name?: string;
};
type Run = {
  status: string; waiting_on: string | null; head: string | null; result: string | null; diff_stat: string | null; duration_s: number | null;
  cost_usd: number | null; over_budget: boolean | null; reason: string | null;
};

const q = (v: unknown) => JSON.stringify(v) ?? String(v);

function parse(args: string[]): Opts {
  const o: any = {};
  for (let i = 0; i < args.length; i++) {
    const m = args[i].match(/^--(role|task|repo|model|timeout|wait|bg|list|result|cleanup|broker|requester|token|profile|project-path|request-name|request)(?:=(.*))?$/s);
    if (!m) throw new DelegateError(`unknown option or argument ${visible(q(args[i]).slice(0, 80))} (nc delegate help)`);
    const key = m[1];
    if (o[key] !== undefined) throw new DelegateError(`--${key} given more than once`);
    if (key === "wait" || key === "bg" || key === "list" || key === "broker") {
      if (m[2] !== undefined) throw new DelegateError(`--${key} takes no value`);
      o[key] = true;
      continue;
    }
    const value = m[2] ?? args[++i];
    if (value === undefined) throw new DelegateError(`--${key} needs a value`);
    o[key] = value;
  }
  return o;
}

/** Every ID from outside is checked before it is used anywhere (path, argv, ref). */
function checkId(id: string): string {
  if (!ID.test(id)) throw new DelegateError(`invalid ID ${visible(q(id).slice(0, 60))} (expected d<MMDD>-<hhmm>-<4 hex>)`);
  return id;
}

type Out = { code: number; out: string; err: string };
/** argv only, never a shell; a timeout on every call. */
function run(argv: string[], opts: { cwd?: string; timeout?: number; env?: Record<string, string | undefined> } = {}): Out {
  const r = Bun.spawnSync(argv, { cwd: opts.cwd ?? "/", stdin: "ignore", stdout: "pipe", stderr: "pipe", timeout: (opts.timeout ?? 60) * 1000, env: opts.env ?? gitEnv() });
  return { code: r.exitCode ?? 124, out: r.stdout.toString(), err: r.stderr.toString() };
}
/** The environment without git variables that would point -C somewhere else. */
function gitEnv(): Record<string, string | undefined> {
  const env = { ...process.env, GIT_TERMINAL_PROMPT: "0" };
  for (const k of ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_EXTERNAL_DIFF"])
    delete env[k];
  return env;
}
const lastLine = (s: string) => visible(s.trim().split("\n").at(-1) ?? "").slice(0, 400);
const git = (dir: string, args: string[], timeout = 60) => run(["git", "-C", dir, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", ...args], { timeout });
const sleep = (ms: number) => Bun.sleepSync(ms);

function real(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    throw new DelegateError(`path not found: ${visible(p)}`);
  }
}
const inside = (p: string, root: string) => p === root || p.startsWith(root.endsWith("/") ? root : root + "/");

function writeAtomic(path: string, text: string | Uint8Array, mode = 0o600) {
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, text, { mode });
  renameSync(tmp, path);
}

function newId(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `d${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}-${randomBytes(2).toString("hex")}`;
}

function prompt(r: Request, task: string): string {
  return `# Contract for this task (nc delegate)

You work as a worker of nc delegate, role ${r.role}, task ${r.task_id}. Time limit: ${r.timeout_min} minutes.

- Work only in /workspace. Push nothing (it would not work anyway), do not switch the branch.
- At the end commit everything on the current branch. What is not committed does not arrive.
- Last, write /home/agent/.nc/RESULT.md – outside the repo, do not commit it.
  The first line is exactly one of these four:
    STATUS: done
    STATUS: cannot_complete
    STATUS: requires_user_auth
    STATUS: waiting_on <task-id>
  After it: summary, changed files, tests run, open questions.
- requires_user_auth: something is missing that the container does not have (GitHub, sudo, push, a key).
  cannot_complete: not doable this way, with the reason.

# Task

${task}
`;
}

// --- checks shared by host, broker and container ---------------------------------------------------------------

/** --task, --timeout, --model and --wait/--bg, checked the same way everywhere. */
function checkOptions(o: Opts): { task: string; timeout: number } {
  const task = o.task ?? "";
  if (o.wait && o.bg) throw new DelegateError("--wait and --bg exclude each other");
  if (!task.trim()) throw new DelegateError("--task missing or empty");
  if (Buffer.byteLength(task, "utf8") > TASK_BYTES) throw new DelegateError(`--task has ${Buffer.byteLength(task, "utf8")} bytes, at most ${TASK_BYTES}`);
  const timeout = o.timeout === undefined ? 20 : /^[0-9]{1,2}$/.test(o.timeout) ? Number(o.timeout) : NaN;
  if (!(timeout >= 1 && timeout <= 20)) throw new DelegateError(`--timeout ${visible(q(o.timeout))}: whole minutes from 1 to 20`);
  if (o.model !== undefined && !MODEL.test(o.model)) throw new DelegateError(`--model ${visible(q(o.model).slice(0, 80))}: not a valid model ID`);
  return { task, timeout };
}

function checkRole(role: string) {
  if (role === "researcher") throw new Refused(RESEARCHER);
  if (!WORKER_ROLES.includes(role))
    throw new Refused(`role ${visible(q(role).slice(0, 60))} not as a worker – only ${WORKER_ROLES.join(", ")}; for planner and reviewer use native subagents (Claude workers are off)`);
}

type Resolved = { class: string; model: string; isolation: "container" | null; require: string[] };

/**
 * Whether a worker may start: "ok", "isolation" (the class runs only in a container and there is none) or
 * "no-container" (no container, and the class would not need one; still no worker: workers exist only on the server,
 * there is no worktree way).
 */
export function requireContainer(isolation: "container" | null, hasContainer: boolean): "ok" | "isolation" | "no-container" {
  if (hasContainer) return "ok";
  return isolation === "container" ? "isolation" : "no-container";
}

const NO_NC_WORK = "nc-work not found – no container, no worker; workers exist only on the server";

/** Refused unless nc-work is there; the message says whether the policy asks for the container. Before tools(). */
function checkContainer(res: Resolved, path: string) {
  const verdict = requireContainer(res.isolation, Bun.which("nc-work") !== null);
  if (verdict === "isolation") throw new Refused(`class ${res.class} in ${path} only in a container (isolation) – without nc-work no worker`);
  if (verdict === "no-container") throw new Refused(NO_NC_WORK);
}

/** Policy through bin/nc, like cli/claude.sh: `nc models resolve` and, with a model, `nc models check`. Only exit 0 allows. */
function policy(repo: string, checkout: string, role: string, model: string | null): Resolved {
  const nc = join(repo, "bin/nc");
  const resolved = run([nc, "models", "resolve", "--role", role, "--path", checkout, "--json"], { timeout: 30 });
  if (resolved.code !== 0) {
    const reason = lastLine(resolved.err).replace(/^nc models: /, "") || `exit ${resolved.code}`;
    if (resolved.code === 1) throw new Refused(`nc models resolve: ${reason}`);
    throw new DelegateError(`nc models resolve: ${reason}`);
  }
  let res: { class: string; runtime: string; model: string | null; isolation?: unknown; require?: unknown };
  try {
    res = JSON.parse(resolved.out);
  } catch {
    throw new DelegateError("nc models resolve --json: no JSON answer");
  }
  if (res.runtime === "claude-code") throw new Refused(`role ${role} is class ${res.class} (claude-code): use native subagents; Claude workers are off`);
  if (res.runtime !== "opencode" || typeof res.model !== "string" || !MODEL.test(res.model)) throw new DelegateError(`nc models resolve: unexpected answer ${visible(resolved.out.trim()).slice(0, 200)}`);
  if (!("isolation" in res) || !("require" in res)) throw new DelegateError("nc models resolve --json: isolation or require missing – harness too old (update nc-harness)");
  if ((res.isolation !== null && res.isolation !== "container") || !Array.isArray(res.require) || !res.require.every((v) => typeof v === "string"))
    throw new DelegateError(`nc models resolve: unexpected answer ${visible(resolved.out.trim()).slice(0, 200)}`);
  if (model !== null) {
    const checked = run([nc, "models", "check", "--model", model, "--path", checkout], { timeout: 30 });
    if (checked.code !== 0) {
      const reason = lastLine(checked.err).replace(/^nc models: /, "") || `exit ${checked.code}`;
      if (checked.code === 1) throw new Refused(`nc models check: ${reason}`);
      throw new DelegateError(`nc models check: ${reason}`);
    }
  }
  return { class: res.class, model: res.model, isolation: res.isolation, require: res.require };
}

function tools(): { ncWork: string; hc: string } {
  const ncWork = Bun.which("nc-work");
  if (!ncWork) throw new Refused(NO_NC_WORK);
  const hc = Bun.which("hc");
  if (!hc) throw new DelegateError("hc not found – workers run as a herdr terminal (install herdr-core)");
  return { ncWork, hc };
}

// --- start: create the worker task and its terminal --------------------------------------------------------------

type Launch = {
  profile: string; checkout: string; role: string; cls: string; model: string; override: string | null; timeout: number; task: string;
  /** Host: the checkout's HEAD. Broker: null, taken from nc-work create's record. */
  base: string | null;
  broker?: { requester: string; token: string; requestName: string };
};

/** A worker task that was just created and is not used: removed again, with the command in the message if that fails. */
function discard(ncWork: string, id: string, dir: string, why: string): never {
  const removed = run([ncWork, "remove", id, "--force"], { timeout: 300 });
  if (removed.code === 0) rmSync(dir, { recursive: true, force: true });
  throw new DelegateError(`${why} – ${removed.code === 0 ? `task ${id} and run folder deleted again` : `task ${id} not deleted: nc-work remove ${id} --force`}`);
}

/** nc-work create's record on stdout (indented JSON, possibly after other lines). */
function createdRecord(out: string): any {
  const text = out.trim();
  for (const start of [0, text.lastIndexOf("\n{") + 1]) {
    try {
      const r = JSON.parse(text.slice(start));
      if (r && typeof r === "object") return r;
    } catch {}
  }
  return null;
}

function launch(repo: string, home: string, l: Launch): Request {
  const { ncWork, hc } = tools();
  // The harness checkout the hc terminal runs from, fixed here: NC_REPO is not set there.
  const runner = join(real(repo), "cli/delegate-run.sh");
  if (runner.includes("'")) throw new DelegateError(`a harness path with ' is not supported: ${runner}`);

  // All checks passed: from here on things get created.
  const runs = join(home, ".nc/delegate");
  mkdirSync(runs, { recursive: true, mode: 0o700 });
  let id = "";
  let dir = "";
  for (let i = 0; ; i++) {
    id = newId();
    dir = join(runs, id);
    try {
      mkdirSync(dir, { mode: 0o700 });
      break;
    } catch (e: any) {
      if (e?.code !== "EEXIST" || i >= 5) throw new DelegateError(`run folder ${dir} not created: ${e?.message ?? e}`);
    }
  }
  chmodSync(dir, 0o700);

  const extra = l.broker ? ["--from-task", l.broker.requester] : [];
  const created = run([ncWork, "create", l.profile, id, "--worker", ...extra], { timeout: 900 });
  if (created.code !== 0) {
    rmSync(dir, { recursive: true, force: true });
    const reason = created.err ? lastLine(created.err).replace(/^nc-work: /, "") : `exit ${created.code}`;
    if (created.code === 3) throw new Refused(`3 tasks running – nc delegate stops none (nc-work: ${reason})`);
    if (created.code === 4) throw new Refused(reason);
    const left = recordLeft(ncWork, id);
    throw new DelegateError(`nc-work create: ${reason}${left ? ` – a record was left behind: nc-work remove ${id} --force` : ""}`);
  }
  let base = l.base;
  if (l.broker) {
    // The base is nc-work's verified commit of the requester, never anything from the request or the container.
    const rec = createdRecord(created.out);
    if (!rec || rec.id !== id || rec.worker !== true || rec.from_task !== l.broker.requester || rec.from_token !== l.broker.token || typeof rec.base !== "string" || !SHA.test(rec.base))
      discard(ncWork, id, dir, "nc-work create: the record does not match the request (worker, from_task, from_token or base)");
    base = rec.base;
  }

  const req: Request = {
    task_id: id, role: l.role, class: l.cls, model: l.override ?? l.model, model_override: l.override, profile: l.profile,
    checkout: l.checkout, base: base!, timeout_min: l.timeout, started: new Date().toISOString(),
    ...(l.broker ? { origin: "broker" as const, requester: l.broker.requester, requester_token: l.broker.token, request_name: l.broker.requestName } : {}),
  };
  writeAtomic(join(dir, "prompt.md"), prompt(req, l.task));
  writeAtomic(join(dir, "request.json"), JSON.stringify(req, null, 2) + "\n");

  // No task text on hc's command line: delegate-run.sh reads prompt.md.
  const started = run([hc, "run", "--bg", "--no-notify", "--outlive-parent", "--name", id, "--", "bash", "-lc", `'${runner}' ${id}`], { cwd: dir, timeout: 30 });
  if (started.code !== 0) {
    let kind = "";
    try {
      kind = JSON.parse(started.out)?.error?.kind ?? "";
    } catch {}
    discard(ncWork, id, dir, `hc run: exit ${started.code}${kind ? ` (${visible(String(kind)).slice(0, 60)})` : started.err ? `, ${lastLine(started.err)}` : ""}`);
  }
  return req;
}

/** Host: from a checkout under ~/projects. */
function start(repo: string, home: string, o: Opts): number {
  const role = o.role!;
  const { task, timeout } = checkOptions(o);
  checkRole(role);
  const asked = real(o.repo ?? process.cwd());
  // Without nc-work there is no profile list: the policy of the asked folder decides which refusal it is.
  const ncWork = Bun.which("nc-work");
  if (!ncWork) {
    checkContainer(policy(repo, asked, role, o.model ?? null), asked);  // refuses: without nc-work there is no worker
    throw new Refused("nc-work not found – no container, no worker");
  }

  // Profile: deepest profile checkout containing the real path of --repo; work with the profile root.
  const listed = run([ncWork, "profiles", "--json"], { timeout: 30 });
  if (listed.code !== 0) throw new DelegateError(`nc-work profiles --json: exit ${listed.code}${listed.err ? `, ${lastLine(listed.err)}` : ""}`);
  let profiles: { id: string; path: string }[];
  try {
    profiles = JSON.parse(listed.out);
    if (!Array.isArray(profiles)) throw new Error();
  } catch {
    throw new DelegateError("nc-work profiles --json: not a JSON list");
  }
  let profile: { id: string; root: string } | null = null;
  for (const p of profiles) {
    if (!p || typeof p.id !== "string" || !PROFILE_ID.test(p.id) || typeof p.path !== "string" || !p.path || p.path.startsWith("/")) continue;
    let root: string;
    try {
      root = realpathSync(join(home, "projects", p.path));
    } catch {
      continue;
    }
    if (inside(asked, root) && (!profile || root.length > profile.root.length)) profile = { id: p.id, root };
  }
  if (!profile) throw new Refused(`${asked} lies in no nc-work profile – workers only for repos in an nc-work profile`);
  const top = git(asked, ["rev-parse", "--show-toplevel"]);
  if (top.code !== 0) throw new Refused(`${asked} is not a git repo`);
  const topReal = real(top.out.trim());
  if (topReal !== profile.root)
    throw new Refused(`${asked} belongs to the repo ${topReal}, not to the checkout ${profile.root} of the profile ${profile.id} (another worktree or an embedded repo)`);
  const checkout = profile.root;

  const res = policy(repo, checkout, role, o.model ?? null);
  checkContainer(res, checkout);
  tools();

  const dirty = git(checkout, ["--no-optional-locks", "status", "--porcelain"]);
  if (dirty.code !== 0) throw new DelegateError(`git status in ${checkout}: ${lastLine(dirty.err)}`);
  if (dirty.out.trim()) throw new Refused(`${checkout} has local changes – the worker starts from the last commit; commit or clean up first`);
  const head = git(checkout, ["rev-parse", "--verify", "HEAD"]);
  if (head.code !== 0 || !SHA.test(head.out.trim())) throw new DelegateError(`${checkout}: no commit (git rev-parse HEAD)`);

  const req = launch(repo, home, {
    profile: profile.id, checkout, role, cls: res.class, model: res.model, override: o.model ?? null, timeout, task, base: head.out.trim(),
  });
  if (o.bg) {
    console.log(JSON.stringify(output(req, running())));
    return 0;
  }
  return result(repo, home, req.task_id, true, ["--result", req.task_id, "--wait"]);
}

/**
 * Broker, host only: `nc delegate --broker --requester T --token TOK --profile P --project-path PATH
 * --request FILE --request-name NAME`, called by nc-work broker. T, TOK, P and PATH are nc-work's records of the
 * task that owns the mailbox; FILE is the request in the broker's staging area. The request is read like an nc memory
 * request and checked whole; role, nc models resolve/check run for ~/projects/<PATH> exactly as on the host. No
 * --repo and no clean-checkout check: the worker does not start from the checkout. Returns the started line.
 */
function brokerStart(repo: string, home: string, o: Opts): { task_id: string; timeout_min: number; started: string } {
  if (process.env.NC_HARNESS_VERSION) throw new DelegateError("--broker exists only on the host (nc-work broker)");
  const allowed = new Set(["broker", "requester", "token", "profile", "project-path", "request", "request-name"]);
  const extra = Object.keys(o).filter((k) => !allowed.has(k));
  if (extra.length) throw new DelegateError(`--broker takes only --requester, --token, --profile, --project-path, --request and --request-name (not --${extra[0]})`);
  const missing = [...allowed].filter((k) => k !== "broker" && (o as any)[k] === undefined);
  if (missing.length) throw new DelegateError(`--broker needs --${missing.join(", --")}`);
  const requester = o.requester!, token = o.token!, profile = o.profile!, path = o["project-path"]!, name = o["request-name"]!;
  if (!TASK_NAME.test(requester)) throw new DelegateError(`--requester ${visible(q(requester).slice(0, 60))}: not a task name`);
  if (!TOKEN.test(token)) throw new DelegateError("--token: expected 32 hex characters");
  if (!PROFILE_ID.test(profile)) throw new DelegateError(`--profile ${visible(q(profile).slice(0, 60))}: not a profile name`);
  if (!PROJECT_PATH.test(path) || path.split("/").some((part) => part === "." || part === ".."))
    throw new DelegateError(`--project-path ${visible(q(path).slice(0, 80))}: not a project path relative to ~/projects`);
  if (!REQUEST_NAME.test(name)) throw new DelegateError(`--request-name ${visible(q(name).slice(0, 80))}: not a request name`);

  let r;
  try {
    r = checkRequest(parseObject(readBounded(o.request!, REQUEST_BYTES)));
  } catch (e) {
    if (e instanceof RequestError) throw new Refused(`request ${name}: ${e.message}`);
    throw e;
  }
  if (r.type !== "delegate") throw new Refused(`request ${name}: type ${r.type} does not go through --broker`);
  checkRole(r.role);

  const projects = real(join(home, "projects"));
  const checkout = real(join(projects, path));
  if (!inside(checkout, projects) || !statSync(checkout).isDirectory()) throw new DelegateError(`~/projects/${path} is not a folder under ~/projects`);
  const res = policy(repo, checkout, r.role, r.model);
  checkContainer(res, checkout);
  tools();
  const req = launch(repo, home, {
    profile, checkout, role: r.role, cls: res.class, model: res.model, override: r.model, timeout: r.timeout, task: r.task, base: null,
    broker: { requester, token, requestName: name },
  });
  return { task_id: req.task_id, timeout_min: req.timeout_min, started: req.started };
}

/** In --broker mode there is always exactly one JSON line on stdout, also for unexpected errors. */
function brokerEntry(repo: string, home: string, args: string[]): number {
  let line: Record<string, unknown>;
  let code: number;
  try {
    line = { state: "started", ...brokerStart(repo, home, parse(args)) };
    code = 0;
  } catch (e: any) {
    const known = e instanceof DelegateError || e instanceof Refused;
    const reason = visible(known ? e.message : `unexpected error: ${e?.message ?? e}`).slice(0, REASON_CHARS);
    line = { state: e instanceof Refused ? "refused" : "error", reason };
    code = e instanceof Refused ? 1 : 2;
  }
  process.stdout.write(JSON.stringify(line) + "\n");
  return code;
}

/**
 * Whether nc-work still has a record for `id`. `nc-work status` prints the record (indented JSON) and then runs
 * `docker port` on the proxy, which fails (exit 1) for a failed create whose proxy never started: the printed
 * record counts, not the exit code.
 */
function recordLeft(ncWork: string, id: string): boolean {
  const st = run([ncWork, "status", id], { timeout: 30 });
  if (st.code === 0) return true;
  const end = st.out.indexOf("\n}");
  if (!st.out.startsWith("{") || end < 0) return false;
  try {
    return JSON.parse(st.out.slice(0, end + 2))?.id === id;
  } catch {
    return false;
  }
}

// --- result ------------------------------------------------------------------------------------------

const running = (): Run => ({ status: "running", waiting_on: null, head: null, result: null, diff_stat: null, duration_s: null, cost_usd: null, over_budget: null, reason: null });

function output(r: Request, x: Run) {
  return {
    task_id: r.task_id, role: r.role, runtime: "opencode", model: r.model, status: x.status, waiting_on: x.waiting_on,
    branch: `nc-work/${r.task_id}`, ref: `refs/nc-delegate/${r.task_id}`, base: r.base, head: x.head, result: x.result,
    diff_stat: x.diff_stat, duration_s: x.duration_s, cost_usd: x.cost_usd, over_budget: x.over_budget, reason: x.reason,
  };
}

const EVENTS_MAX = 16 * 1024 * 1024;
const EVENT_LINE_MAX = 1024 * 1024;

/**
 * Sum of part.cost of the step_finish events in <run folder>/events.jsonl, as OpenCode in the worker reported them.
 * Only a regular file (no link) of at most 16 MiB; lines over 1 MiB, broken JSON, strings, NaN and negative values
 * are skipped. null without a valid step_finish (also: no file, older runs) or with a sum that is not finite.
 */
export function eventsCost(path: string): number | null {
  let fd: number;
  try {
    fd = openSync(path, fsc.O_RDONLY | fsc.O_NOFOLLOW | fsc.O_NONBLOCK);
  } catch {
    return null;
  }
  let data: Buffer;
  try {
    const st = fstatSync(fd);
    if (!st.isFile() || st.size > EVENTS_MAX) return null;
    data = Buffer.alloc(st.size);
    let got = 0;
    while (got < st.size) {
      const n = readSync(fd, data, got, st.size - got, got);
      if (n <= 0) break;
      got += n;
    }
    data = data.subarray(0, got);
  } finally {
    closeSync(fd);
  }
  let sum = 0;
  let seen = 0;
  for (let start = 0; start < data.length; ) {
    let end = data.indexOf(0x0a, start);
    if (end < 0) end = data.length;
    const line = data.subarray(start, end);
    start = end + 1;
    if (line.length === 0 || line.length > EVENT_LINE_MAX) continue;
    try {
      const e = JSON.parse(line.toString("utf8"));
      const cost = e?.type === "step_finish" ? e?.part?.cost : undefined;
      if (typeof cost === "number" && Number.isFinite(cost) && cost >= 0) {
        sum += cost;
        seen++;
      }
    } catch {}
  }
  if (!seen || !Number.isFinite(sum)) return null;
  return Math.round(sum * 1e4) / 1e4;
}

/**
 * cost_usd and over_budget of a run. Never throws: any fault gives null for both and a warning line on stderr, so a
 * fault here never leaves a stopped worker without result.json. A models.yaml that cannot be read only makes
 * over_budget null.
 */
function costAndBudget(repo: string, dir: string): { cost_usd: number | null; over_budget: boolean | null; limit: number | null } {
  try {
    const cost = eventsCost(join(dir, "events.jsonl"));
    let limit: number | null = null;
    try {
      limit = loadModels(repo).budgets.per_task_usd ?? null;
    } catch (e: any) {
      process.stderr.write(`nc delegate: warning: budget not read (${visible(String(e?.message ?? e)).slice(0, 200)}) – over_budget null\n`);
    }
    return { cost_usd: cost, over_budget: cost === null || limit === null ? null : cost > limit, limit };
  } catch (e: any) {
    process.stderr.write(`nc delegate: warning: cost not determined (${visible(String(e?.message ?? e)).slice(0, 200)})\n`);
    return { cost_usd: null, over_budget: null, limit: null };
  }
}

function runDir(home: string, id: string): string {
  const dir = join(home, ".nc/delegate", id);
  const st = (() => {
    try {
      return lstatSync(dir);
    } catch {
      return null;
    }
  })();
  if (!st || !st.isDirectory()) throw new DelegateError(`no run ${id} (${dir} missing)`);
  return dir;
}

function readRequest(dir: string, id: string): Request {
  try {
    const r = JSON.parse(readFileSync(join(dir, "request.json"), "utf8"));
    const broker = r.origin === undefined || (r.origin === "broker" && TASK_NAME.test(r.requester) && TOKEN.test(r.requester_token) && REQUEST_NAME.test(r.request_name));
    if (r.task_id === id && KNOWN_ROLES.includes(r.role) && typeof r.checkout === "string" && r.checkout.startsWith("/") && SHA.test(r.base) &&
        Number.isInteger(r.timeout_min) && !Number.isNaN(Date.parse(r.started)) && typeof r.model === "string" && PROFILE_ID.test(r.profile) && broker)
      return r;
  } catch {}
  throw new DelegateError(`${dir}/request.json missing or not readable`);
}

/** One JSONL line per run folder under ~/.nc/delegate, oldest start first; unreadable folders last. Never writes. */
function list(home: string): number {
  const root = join(home, ".nc/delegate");
  let names: string[] = [];
  try {
    names = readdirSync(root);
  } catch {}  // no folder: no runs
  const rows: { at: number; line: string }[] = [];
  for (const id of names.sort()) {
    const dir = join(root, id);
    try {
      if (!lstatSync(dir).isDirectory()) continue;
    } catch {
      continue;
    }
    try {
      const req = readRequest(dir, id);
      const file = join(dir, "result.json");
      const collected = existsSync(file);
      const res = collected ? JSON.parse(readFileSync(file, "utf8")) : null;
      if (collected && (typeof res !== "object" || res === null || typeof res.status !== "string")) throw new Error("result.json has no status");
      // Not collected: running until the worker ended (status.json) or its deadline passed (as in --result); then "ended":
      // the worker has stopped and --result collects it. No final status before the collection.
      const deadline = Date.parse(req.started) + (req.timeout_min * 60 + GRACE_S) * 1000;
      const live = !readStatus(dir) && Date.now() < deadline;
      rows.push({ at: Date.parse(req.started), line: JSON.stringify({
        task_id: id, role: req.role, status: res ? res.status : live ? "running" : "ended", started_at: req.started, collected,
        ...(typeof res?.cost_usd === "number" ? { cost_usd: res.cost_usd } : {}), ...(typeof res?.over_budget === "boolean" ? { over_budget: res.over_budget } : {}),
      }) });
    } catch (e: any) {
      rows.push({ at: Infinity, line: JSON.stringify({ task_id: id, status: "unreadable", reason: visible(String(e?.message ?? e)).slice(0, 200) }) });
    }
  }
  rows.sort((a, b) => a.at - b.at);  // stable: ties and unreadable folders stay in name order
  for (const r of rows) console.log(r.line);
  return 0;
}

type Status = { exit: number; ended: number } | null;
function readStatus(dir: string): Status {
  const path = join(dir, "status.json");
  if (!existsSync(path)) return null;
  try {
    const s = JSON.parse(readFileSync(path, "utf8"));
    const ended = Date.parse(s.ended);
    return { exit: Number.isInteger(s.exit) ? s.exit : -1, ended: Number.isNaN(ended) ? Date.now() : ended };
  } catch {
    return { exit: -1, ended: Date.now() };
  }
}

/**
 * Under the lock: bin/nc again, under flock -x, with the marker. No outer timeout: the lock wait (flock -w), the
 * wait for status.json (deadline) and every call of the child have their own limits, and a timeout here would
 * only kill flock and leave the child running on its own.
 */
function underLock(repo: string, dir: string, id: string, args: string[]): number {
  const flock = Bun.which("flock");
  if (!flock) throw new DelegateError("flock not found (util-linux)");
  const r = Bun.spawnSync([flock, "-x", "-w", "900", "-E", "75", join(dir, ".lock"), join(repo, "bin/nc"), "delegate", ...args], {
    cwd: "/", stdio: ["ignore", "inherit", "inherit"], env: { ...process.env, NC_DELEGATE_LOCKED: id },
  });
  if (r.exitCode === 75) throw new DelegateError(`run ${id} has been locked for 15 minutes (another nc delegate is collecting it)`);
  if (r.exitCode === null) throw new DelegateError(`run ${id}: collecting stopped by ${r.signalCode ?? "a signal"} – nc delegate --result ${id} tries again`);
  return r.exitCode;
}

function result(repo: string, home: string, id: string, wait: boolean, args: string[]): number {
  const dir = runDir(home, id);
  const req = readRequest(dir, id);
  const resultFile = join(dir, "result.json");
  const deadline = Date.parse(req.started) + (req.timeout_min * 60 + GRACE_S) * 1000;
  const locked = process.env.NC_DELEGATE_LOCKED === id;

  if (existsSync(resultFile)) {
    process.stdout.write(readFileSync(resultFile, "utf8"));
    return 0;
  }
  // Wait outside the lock, so a --result without --wait is never blocked by a waiting one.
  if (wait) while (!readStatus(dir) && !existsSync(resultFile) && Date.now() < deadline) sleep(2000);
  if (!locked) return underLock(repo, dir, id, args);

  // Without --wait: running until the deadline; past it the worker is fetched with timeout and stopped, like --wait
  // (the broker asks without --wait and relies on that).
  const status = readStatus(dir);
  if (!status && !wait && Date.now() < deadline) {
    console.log(JSON.stringify(output(req, running())));
    return 0;
  }
  return fetchResult(repo, home, dir, req, status);
}

function fetchResult(repo: string, home: string, dir: string, req: Request, status: Status): number {
  const id = req.task_id;
  const ncWork = Bun.which("nc-work");
  if (!ncWork) throw new DelegateError("nc-work not found");
  const exp = join(dir, "export");
  const broker = req.origin === "broker";
  // A stale export or delivery of an earlier attempt: only those paths, never following a link (rmSync does not).
  rmSync(exp, { recursive: true, force: true });
  if (broker) rmSync(join(dir, "delivery"), { recursive: true, force: true });

  // Export before stop: nc-work export needs the running container. A worker that hangs past the deadline is
  // fetched as it is (what is committed counts) and then stopped.
  const exported = run([ncWork, "export", id, "--out", exp], { timeout: 900 });
  if (exported.code !== 0)
    throw new DelegateError(`nc-work export: ${exported.err ? lastLine(exported.err).replace(/^nc-work: /, "") : `exit ${exported.code}`} – nothing collected; if the container is not running: nc-work start ${id}, then nc delegate --result ${id}`);
  let ex: any;
  try {
    ex = JSON.parse(readFileSync(join(exp, "export.json"), "utf8"));
  } catch {
    throw new DelegateError(`${exp}/export.json missing or not readable`);
  }
  if (!SHA.test(ex?.head)) throw new DelegateError(`export.json: no valid head`);
  const head: string = ex.head;
  const base: string = SHA.test(ex.base) ? ex.base : req.base;
  const repoGit = join(exp, "repo.git");
  const branchRef = `refs/heads/nc-work/${id}`;
  const ref = `refs/nc-delegate/${id}`;

  const rawPath = join(exp, "RESULT.raw");
  const raw = ["present", "truncated"].includes(ex.result_file) && existsSync(rawPath) ? readFileSync(rawPath) : null;
  const cleaned = raw ? cleanResult(raw, ex.result_file === "truncated") : null;
  const delivery = join(dir, "delivery");
  if (broker) {
    // No checkout under ~/projects: the branch goes to the requester as a bundle (delivery/), the ref is made there.
    const got = run(["git", "--git-dir", repoGit, "-c", "core.hooksPath=/dev/null", "rev-parse", "--verify", "--quiet", `${branchRef}^{commit}`]);
    if (got.out.trim() !== head) throw new DelegateError(`${branchRef} in export/repo.git does not point to ${head}`);
    // Everything the broker copies into the requester's inbox except result.json, before the worker is stopped: a fault here
    // leaves the worker running for the next --result. result.json (here and in delivery/) stays the last thing written.
    mkdirSync(delivery, { mode: 0o700 });
    const bundle = join(delivery, "result.bundle");
    const made = run(["git", "--git-dir", repoGit, "-c", "core.hooksPath=/dev/null", "bundle", "create", "-q", bundle, branchRef], { timeout: 300 });
    if (made.code !== 0) throw new DelegateError(`git bundle create: ${lastLine(made.err)}`);
    if (statSync(bundle).size > BUNDLE_MAX) throw new DelegateError(`result.bundle larger than ${BUNDLE_MAX / 2 ** 20} MiB`);
    if (cleaned !== null) writeAtomic(join(delivery, "RESULT.md"), cleaned);
  } else {
    const fetched = git(req.checkout, ["-c", "transfer.fsckObjects=true", "-c", "gc.auto=0", "fetch", "--no-tags", "--no-recurse-submodules",
      repoGit, `${branchRef}:${ref}`], 300);
    if (fetched.code !== 0) throw new DelegateError(`git fetch in ${req.checkout}: ${lastLine(fetched.err)}`);
    const got = git(req.checkout, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
    if (got.out.trim() !== head) throw new DelegateError(`${ref} does not point to ${head}`);
  }

  // Before stop: whatever happens here, the worker is fetched and gets its result.json.
  const { limit, ...cost } = costAndBudget(repo, dir);
  const stopped = run([ncWork, "stop", id], { timeout: 120 });
  if (stopped.code !== 0) process.stderr.write(`nc delegate: warning: nc-work stop ${id}: exit ${stopped.code} – the container may still be running\n`);

  // Status by rules, from the raw first line, never from the cleaned text.
  let x: Run = { ...running(), head, ...cost };
  if (!status) {
    x.status = "timeout";
    x.reason = `no end after ${req.timeout_min} minutes and ${GRACE_S / 60} minutes of grace – worker stopped with nc-work stop`;
  } else if (status.exit === 124 || status.exit === 137) {
    x.status = "timeout";
    x.reason = `time limit reached (${req.timeout_min} min, exit ${status.exit})`;
  } else if (status.exit !== 0) {
    x.status = "failed";
    x.reason = status.exit < 0 ? "status.json not readable" : `worker ended with exit ${status.exit}`;
  } else {
    let first = "";
    if (raw) {
      try {
        const nl = raw.indexOf(0x0a);
        first = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(raw.subarray(0, nl < 0 ? raw.length : nl)).replace(/\r$/, "");
      } catch {
        first = "";  // invalid UTF-8 in the first line: no status line
      }
    }
    const m = first.match(STATUS_LINE);
    const w = first.match(WAITING_LINE);
    if (m) x.status = m[1];
    else if (w) {
      x.status = "waiting_on";
      x.waiting_on = w[1];
    } else {
      x.status = "failed";
      x.reason = ex.result_file === "error" ? "RESULT.md not readable" : "RESULT.md missing or without a valid status line";
    }
  }
  x.duration_s = Math.max(0, Math.round(((status?.ended ?? Date.now()) - Date.parse(req.started)) / 1000));

  if (cleaned !== null) {
    const md = join(dir, "RESULT.md");
    writeAtomic(md, cleaned);
    x.result = broker ? `${INBOX_IN_CONTAINER}/${req.request_name!.slice(0, -".json".length)}/RESULT.md` : md;
  }

  const stat = run(["git", "--git-dir", repoGit, "-c", "core.hooksPath=/dev/null", "diff", "--stat", "--no-color", "--no-ext-diff", "--no-textconv", base, head]);
  if (stat.code === 0) {
    const lines = cleanText(stat.out).replaceAll("\t", " ").split("\n").filter((l) => l.trim()).map((l) => l.slice(0, 300));
    x.diff_stat = (lines.length > DIFF_LINES ? [...lines.slice(0, DIFF_LINES - 1), `… ${lines.length - DIFF_LINES + 1} lines cut`] : lines).join("\n");
  }

  const out = output({ ...req, base }, x);
  const json = JSON.stringify(out) + "\n";
  if (broker) writeAtomic(join(delivery, "result.json"), json);
  writeAtomic(join(dir, "result.json"), json);
  const { diff_stat, ...logged } = out;
  const log = join(home, ".nc/log");
  mkdirSync(log, { recursive: true, mode: 0o700 });
  appendFileSync(join(log, "delegate.jsonl"), JSON.stringify({ ...logged, profile: req.profile, ...(broker ? { requester: req.requester } : {}) }) + "\n", { mode: 0o600 });
  if (out.over_budget === true)
    process.stderr.write(`nc delegate: cost (reported by the worker) ${out.cost_usd} $ over per_task_usd ${limit} $\n`);
  process.stdout.write(readFileSync(join(dir, "result.json"), "utf8"));
  return 0;
}

// --- cleanup -----------------------------------------------------------------------------------------

function cleanup(repo: string, home: string, id: string): number {
  const dir = runDir(home, id);
  const req = readRequest(dir, id);
  if (process.env.NC_DELEGATE_LOCKED !== id) return underLock(repo, dir, id, ["--cleanup", id]);
  const broker = req.origin === "broker";
  const ref = `refs/nc-delegate/${id}`;
  // Host: the state comes from the ref in the checkout. Broker: from the host's own export repo, never from a file.
  const got = broker
    ? run(["git", "--git-dir", join(dir, "export/repo.git"), "-c", "core.hooksPath=/dev/null", "rev-parse", "--verify", "--quiet", `refs/heads/nc-work/${id}^{commit}`])
    : git(req.checkout, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
  const sha = got.out.trim();
  if (got.code !== 0 || !SHA.test(sha) || (broker && !existsSync(join(dir, "result.json"))))
    throw new Refused(broker ? `run ${id} is not collected yet – nc delegate --result ${id} first` : `${ref} does not exist in ${req.checkout} – nc delegate --result ${id} first`);
  const ncWork = Bun.which("nc-work");
  if (!ncWork) throw new DelegateError("nc-work not found");
  const removed = run([ncWork, "remove", id, "--delivered", sha], { timeout: 300 });
  if (removed.code !== 0) {
    const reason = removed.err ? lastLine(removed.err).replace(/^nc-work: /, "") : `exit ${removed.code}`;
    if (removed.code === 1) throw new Refused(`nc-work remove: ${reason} – ${broker ? "the run folder stays" : "the ref and the run folder stay"}`);
    throw new DelegateError(`nc-work remove: ${reason} – ${broker ? "the run folder stays" : "the ref and the run folder stay"}`);
  }
  if (!broker) {
    const del = git(req.checkout, ["update-ref", "-d", ref, sha]);
    if (del.code !== 0) throw new DelegateError(`git update-ref -d ${ref}: ${lastLine(del.err)}`);
  }
  rmSync(dir, { recursive: true, force: true });
  console.log(broker ? `${id}: task and run folder deleted` : `${id}: task, ${ref} and run folder deleted`);
  return 0;
}

// --- container: client of the broker ----------------------------------------------------------------------------

const NO_MAILBOX = "this task has no mailbox (workers do not delegate further; a task made by an older nc-work has none)";
/** Names the command, not the herdr menu entry: true before and after herdr-nc renames it. */
const NOT_RUNNING = "broker is not running – start `nc-work broker` in a herdr pane";
/** memory: the harness call takes at most 300 s; a request still unpicked after 6 minutes is taken back (the broker works one
 * request after the other, and a delegate hand-over before it can take up to 20 minutes), and nc memory falls back to the outbox. */
const ANSWER_MS = { delegate: 25 * 60_000, cleanup: 5 * 60_000, memory: 6 * 60_000 };
/** How long the client waits for an answer: ANSWER_MS. NC_DELEGATE_ANSWER_S (tests only, like NC_DELEGATE_STALE_S) can
 * shorten it, kept between 1 second and ANSWER_MS. */
export const answerMs = (kind: keyof typeof ANSWER_MS) => {
  const raw = process.env.NC_DELEGATE_ANSWER_S;
  const s = raw ? Number(raw) : NaN;
  return Number.isFinite(s) ? Math.min(ANSWER_MS[kind], Math.max(1000, Math.round(s * 1000))) : ANSWER_MS[kind];
};
const RESPONSE_BYTES = 1024 * 1024;
/** What the client reads of the host's .dropped in the inbox (the host keeps it below 8 KiB). */
const DROPPED_BYTES = 32 * 1024;
/** Workspace of the task (nc-work: /workspace); the variable exists for tests. */
const workspace = () => process.env.NC_TEST_WORKSPACE || "/workspace";
/** After how many seconds a missing or old heartbeat counts as "broker not running" (60; shorter only in tests). */
const staleMs = () => (Number(process.env.NC_DELEGATE_STALE_S) > 0 ? Number(process.env.NC_DELEGATE_STALE_S) : 60) * 1000;
const POLL_MS = 1000;

export type Mailbox = { requests: string; inbox: string };
/** r: delegate, c: cleanup, m: memory (nc memory add in a task). The broker decides by the content, never by this letter. */
export type RequestKind = "r" | "c" | "m";

export function mailbox(): Mailbox {
  const dirs = [process.env.NC_REQUESTS, process.env.NC_INBOX];
  for (const d of dirs) {
    try {
      if (!d || !statSync(d).isDirectory()) throw new Error();
    } catch {
      throw new DelegateError(NO_MAILBOX);
    }
  }
  return { requests: dirs[0]!, inbox: dirs[1]! };
}

function requestName(kind: RequestKind): string {
  const t = new Date().toISOString().replace(/[-:TZ]/g, "").slice(0, 14);
  return `${kind}${t}-${randomBytes(2).toString("hex")}.json`;
}

/** Into the mailbox as the broker expects it: `.<name>.tmp` written with wx, then renamed. */
export function post(m: Mailbox, kind: RequestKind, body: Record<string, unknown>): string {
  const name = requestName(kind);
  const tmp = join(m.requests, `.${name}.tmp`);
  writeFileSync(tmp, JSON.stringify(body) + "\n", { flag: "wx", mode: 0o644 });
  renameSync(tmp, join(m.requests, name));
  return name;
}

/** The host's answer to one request, or null while there is none (or it is not readable yet). */
function readResponse(m: Mailbox, stem: string): Response | null {
  try {
    const r = parseObject(readBounded(join(m.inbox, stem, "response.json"), RESPONSE_BYTES)) as any;
    if (r.v === 1 && r.request === stem && STATES.includes(r.state)) return r as Response;
  } catch {}
  return null;
}

/**
 * The host's reason for dropping request `stem` without an answer, from <inbox>/.dropped ({"v":1,"entries":[{"request",
 * "reason","ts"}]}, written by the broker only: the inbox is read-only in the container). Null if there is no entry for it, and
 * for every fault: file missing, a link, too large, broken.
 */
function droppedReason(m: Mailbox, stem: string): string | null {
  try {
    const d = parseObject(readBounded(join(m.inbox, ".dropped"), DROPPED_BYTES)) as any;
    if (d.v !== 1 || !Array.isArray(d.entries)) return null;
    const hit = d.entries.find((e: any) => e && typeof e === "object" && e.request === stem);
    if (!hit) return null;
    return visible(typeof hit.reason === "string" && hit.reason ? hit.reason : "without a reason").slice(0, REASON_CHARS);
  } catch {
    return null;
  }
}

export function brokerAlive(m: Mailbox): boolean {
  try {
    const hb = parseObject(readBounded(join(m.inbox, ".broker"), 1024)) as any;
    const ts = Date.parse(hb.ts);
    return hb.v === 1 && !Number.isNaN(ts) && Date.now() - ts < staleMs();
  } catch {
    return false;
  }
}

/** Take the request back out of the mailbox: true if it was still there, false if the broker has picked it up (ENOENT). */
export function takeBack(m: Mailbox, name: string): boolean {
  try {
    unlinkSync(join(m.requests, name));
    return true;
  } catch (e: any) {
    if (e?.code === "ENOENT") return false;
    throw new DelegateError(`request ${name.slice(0, -".json".length)} not taken back (${e?.code ?? e})`);
  }
}

/**
 * Wait for an answer in one of `states`. Is the heartbeat missing or older than 60 s and the request still in the
 * mailbox after 60 s, the client takes it back (unlink), looks once more for an answer after one poll interval (the
 * broker may have read it just before and still be writing) and stops: the broker does not run. ENOENT: the broker has picked it up meanwhile, so the client keeps
 * waiting, at most `maxMs`. Then it takes the request back if it is still there and stops with exit 2 either way. The broker
 * stages a request before it deletes it from the mailbox, so a request taken back may still have been accepted just then:
 * after a take-back the client looks once more after one poll interval and returns a late answer.
 *
 * A take-back that worked ends with TakenBack (exit 2, the texts as before). An entry for the request in the host's .dropped
 * (full inbox, mailbox cut to 8 files) ends the wait at once with Refused (exit 1) – looked at in every round after the answer
 * and after every late look; an answer folder always wins.
 */
export function awaitAnswer(m: Mailbox, name: string, states: string[], maxMs: number): Response {
  const stem = name.slice(0, -".json".length);
  const begin = Date.now();
  const answer = () => {
    const r = readResponse(m, stem);
    if (r && states.includes(r.state)) return r;
    const dropped = droppedReason(m, stem);
    if (dropped !== null) throw new Refused(`request ${stem} dropped without an answer: ${dropped}`);
    return null;
  };
  let pickedUp = false;
  for (;;) {
    const r = answer();
    if (r) return r;
    if (!pickedUp && Date.now() - begin >= staleMs() && !brokerAlive(m)) {
      pickedUp = !takeBack(m, name);
      if (!pickedUp) {
        sleep(POLL_MS);
        const late = answer();
        if (late) return late;
        throw new TakenBack(NOT_RUNNING);
      }
    }
    if (Date.now() - begin > maxMs) {
      const late = answer();
      if (late) return late;
      const after = maxMs >= 60_000 ? `${Math.round(maxMs / 60_000)} minutes` : `${Math.round(maxMs / 1000)} seconds`;
      if (!takeBack(m, name)) throw new DelegateError(`in progress – look in the inbox later (request ${stem})`);
      sleep(POLL_MS);
      const accepted = answer();
      if (accepted) return accepted;
      throw new TakenBack(
        `no answer after ${after} – request taken back; if the broker accepted it just before, the answer shows up in the inbox later (request ${stem})`,
      );
    }
    sleep(POLL_MS);
  }
}

export const reasonOf = (r: Response) => visible(typeof r.reason === "string" ? r.reason : "without a reason").slice(0, REASON_CHARS);

/** The answer folder of a delegation (requests named r…) whose response.json has this task_id. */
function findRun(m: Mailbox, id: string): { stem: string; resp: Response } | null {
  let names: string[];
  try {
    names = readdirSync(m.inbox).sort();
  } catch {
    return null;
  }
  for (const stem of names) {
    if (!/^r[a-z0-9-]{0,63}$/.test(stem)) continue;
    const resp = readResponse(m, stem);
    if (resp?.task_id === id) return { stem, resp };
  }
  return null;
}

function containerRunning(id: string, role: string | null) {
  return {
    task_id: id, role, runtime: "opencode", model: null, status: "running", waiting_on: null, branch: `nc-work/${id}`, ref: `refs/nc-delegate/${id}`,
    base: null, head: null, result: null, diff_stat: null, duration_s: null, cost_usd: null, over_budget: null, reason: null,
  };
}

/** Text from the host about a worker: control and invisible characters removed from every string. */
function cleanJson(v: unknown): unknown {
  if (typeof v === "string") return cleanText(v);
  if (Array.isArray(v)) return v.map(cleanJson);
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [cleanText(k), cleanJson(x)]));
  return v;
}

/** done: the branch from the bundle as refs/nc-delegate/<id> in /workspace, once; then the host's JSON. */
function deliver(m: Mailbox, id: string, stem: string, resp: Response): number {
  const res = resp.result as any;
  if (!res || res.task_id !== id || !SHA.test(res.head)) throw new DelegateError(`answer ${stem}: result without a valid head`);
  const ref = `refs/nc-delegate/${id}`;
  const ws = workspace();
  const have = git(ws, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]).out.trim();
  if (have !== res.head) {
    const fetched = git(ws, ["-c", "transfer.fsckObjects=true", "-c", "gc.auto=0", "fetch", "--no-tags", "--no-recurse-submodules",
      join(m.inbox, stem, "result.bundle"), `refs/heads/nc-work/${id}:${ref}`], 300);
    if (fetched.code !== 0) throw new DelegateError(`git fetch from ${join(m.inbox, stem, "result.bundle")}: ${lastLine(fetched.err)}`);
    const got = git(ws, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]).out.trim();
    if (got !== res.head) throw new DelegateError(`${ref} does not point to ${res.head}`);
  }
  if (res.over_budget === true) process.stderr.write(`nc delegate: cost (reported by the worker) ${visible(String(res.cost_usd)).slice(0, 40)} $ over per_task_usd\n`);
  console.log(JSON.stringify(cleanJson(res)));
  return 0;
}

function clientResult(m: Mailbox, id: string, wait: boolean, role: string | null = null): number {
  for (;;) {
    const found = findRun(m, id);
    if (!found) throw new DelegateError(`no run ${id} in the inbox ${m.inbox}`);
    const { stem, resp } = found;
    if (resp.state === "done") return deliver(m, id, stem, resp);
    if (resp.state === "error") throw new DelegateError(`run ${id}: ${reasonOf(resp)}`);
    if (resp.state !== "started") throw new DelegateError(`run ${id}: unexpected state ${visible(String(resp.state))}`);
    if (!wait) {
      console.log(JSON.stringify(containerRunning(id, role)));
      return 0;
    }
    const started = Date.parse(String(resp.started));
    const minutes = Number.isInteger(resp.timeout_min) ? resp.timeout_min! : 20;
    if (Number.isNaN(started) || Date.now() > started + (minutes + 5) * 60_000)
      throw new DelegateError(`no result yet – nc delegate --result ${id} later`);
    sleep(2000);
  }
}

function clientCleanup(m: Mailbox, id: string): number {
  // head first: the broker deletes the run's answer folder when it cleans up.
  const found = findRun(m, id);
  const head = found?.resp.state === "done" && SHA.test((found.resp.result as any)?.head) ? (found.resp.result as any).head as string : null;
  const name = post(m, "c", { v: 1, type: "cleanup", task_id: id });
  const r = awaitAnswer(m, name, ["cleaned", "refused", "error"], answerMs("cleanup"));
  if (r.state === "refused") throw new Refused(`cleanup ${id}: ${reasonOf(r)}`);
  if (r.state !== "cleaned") throw new DelegateError(`cleanup ${id}: ${reasonOf(r)}`);
  const ref = `refs/nc-delegate/${id}`;
  // gone: the host had nothing left to clean up; the local ref goes whatever it points to (its current value).
  const current = git(workspace(), ["rev-parse", "--verify", "--quiet", ref]);
  const expected = r.gone === true ? current.out.trim() : head;
  let dropped = false;
  if (expected && current.code === 0 && SHA.test(current.out.trim())) {
    const del = git(workspace(), ["update-ref", "-d", ref, expected]);
    if (del.code !== 0) throw new DelegateError(`git update-ref -d ${ref}: ${lastLine(del.err)}`);
    dropped = true;
  }
  const what = r.gone === true ? "was already deleted on the host, answer deleted" : "worker task, run folder and answer deleted";
  console.log(`${id}: ${what}${dropped ? `, ${ref} too` : ""}`);
  return 0;
}

function client(o: Opts): number {
  if (o.list) throw new Refused("--list is host-only for now (not in a task container)");
  const modes = [o.role !== undefined, o.result !== undefined, o.cleanup !== undefined].filter(Boolean).length;
  if (modes !== 1) throw new DelegateError("give exactly one of --role, --result and --cleanup (nc delegate help)");
  if (o.repo !== undefined) throw new DelegateError("there is no --repo in a task container – the task's project always applies");
  if (o.result !== undefined) {
    if (Object.keys(o).some((k) => k !== "result" && k !== "wait")) throw new DelegateError("--result takes only --wait with it");
    const id = checkId(o.result);
    return clientResult(mailbox(), id, !!o.wait);
  }
  if (o.cleanup !== undefined) {
    if (Object.keys(o).length !== 1) throw new DelegateError("--cleanup takes no other options");
    const id = checkId(o.cleanup);
    return clientCleanup(mailbox(), id);
  }
  const role = o.role!;
  const { task, timeout } = checkOptions(o);
  if (role === "researcher") throw new Refused(RESEARCHER);
  if (!/^[a-z][a-z0-9-]{0,39}$/.test(role)) throw new Refused(`role ${visible(q(role).slice(0, 60))} not as a worker – only ${WORKER_ROLES.join(", ")}`);
  const m = mailbox();
  const name = post(m, "r", { v: 1, type: "delegate", role, task, model: o.model ?? null, timeout });
  const r = awaitAnswer(m, name, ["refused", "error", "started", "done"], answerMs("delegate"));
  if (r.state === "refused") throw new Refused(reasonOf(r));
  if (r.state === "error") throw new DelegateError(reasonOf(r));
  if (typeof r.task_id !== "string" || !ID.test(r.task_id)) throw new DelegateError(`answer ${name}: no valid task_id`);
  return clientResult(m, r.task_id, !o.bg, role);
}

// --- nc doctor ---------------------------------------------------------------------------------------

type Check = { name: string; status: "ok" | "warn" | "fail"; detail: string };

/** In a task container: mailbox and inbox there, heartbeat of the broker fresh. Warnings only. */
export function delegateCheckIsolated(): Check {
  const name = "nc delegate";
  let m: Mailbox;
  try {
    m = mailbox();
  } catch {
    return { name, status: "warn", detail: `NC_REQUESTS/NC_INBOX missing – ${NO_MAILBOX}` };
  }
  return brokerAlive(m)
    ? { name, status: "ok", detail: `mailbox ${m.requests}, inbox ${m.inbox}, broker running` }
    : { name, status: "warn", detail: `mailbox ${m.requests}, inbox ${m.inbox}; ${NOT_RUNNING}` };
}

// --- entry -------------------------------------------------------------------------------------------

export function delegate(repo: string, home: string, args: string[]): number {
  if (args[0] === "help" || args[0] === "-h" || args[0] === "--help") {
    process.stdout.write(HELP);
    return 0;
  }
  if (args.includes("--broker")) return brokerEntry(repo, home, args);
  try {
    const o = parse(args);
    if (o.list && Object.keys(o).length !== 1) throw new DelegateError("--list takes no other options (nc delegate help)");
    if (process.env.NC_HARNESS_VERSION) return client(o);
    if (o.list) return list(home);
    const modes = [o.role !== undefined, o.result !== undefined, o.cleanup !== undefined].filter(Boolean).length;
    if (modes !== 1) throw new DelegateError("give exactly one of --role, --result and --cleanup (nc delegate help)");
    if (o.result !== undefined) {
      if (Object.keys(o).some((k) => k !== "result" && k !== "wait")) throw new DelegateError("--result takes only --wait with it");
      const id = checkId(o.result);
      return result(repo, home, id, !!o.wait, ["--result", id, ...(o.wait ? ["--wait"] : [])]);
    }
    if (o.cleanup !== undefined) {
      if (Object.keys(o).length !== 1) throw new DelegateError("--cleanup takes no other options");
      return cleanup(repo, home, checkId(o.cleanup));
    }
    return start(repo, home, o);
  } catch (e: any) {
    const message = e instanceof DelegateError || e instanceof Refused ? e.message : `unexpected error: ${e?.message ?? e}`;
    process.stderr.write(`nc delegate: ${message}\n`);
    return e instanceof Refused ? 1 : 2;
  }
}

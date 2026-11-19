/**
 * nc models – what models.yaml allows in a folder. The one place that answers which role gets
 * which model: `nc models` shows it for a folder, `resolve` answers it for one class or role, `check` says
 * whether a model (and, with --host, OpenCode on the host) is allowed there. `orchestrator` prints model and
 * effort of claude_code.orchestrator for nc claude (exit 1 if the block is not set).
 *
 * Exit codes: 0 allowed, 1 refused, 2 error (wrong call, broken models.yaml, unknown project path, path that
 * cannot be resolved). The reason goes to stderr. Only exit 0 is a permission.
 *
 * Reads only ~/.nc/overlay/models.yaml (on the host, when ~/.nc/overlay exists) or <repo>/models.yaml; inside a
 * task container only <repo>/models.yaml. There is deliberately no option and no environment variable for another
 * file: it would be a switch that turns the check off.
 *
 * Early refusal: where a policy denies free or has a `require`, `check --model` allows only the exact
 * model IDs of the classes allowed there – a mirror of the guardrail of the OpenRouter workspace "clients" for a
 * better message, not the limit itself.
 *
 * Limits: elsewhere `check` knows no catalogue. A free model without `:free` in its ID and a router of an author
 * not named in ROUTERS pass. Inside a task container nc itself enforces nothing; nc-work picks the OpenRouter key
 * by this policy (the workspace "clients" where free is denied or no-training required), and that workspace's
 * guardrail is the limit.
 */
import { lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, basename, isAbsolute, join, resolve as lexical } from "node:path";
import { mode } from "./mode.ts";

/** Exit 2. Never a permission. */
export class ModelsError extends Error {}
/** Exit 1: asked correctly, and the answer is no. */
class Refused extends Error {}

type Class = { runtime: "claude-code" | "opencode"; model: string | null; placeholder: boolean };
type Rule = { match: string; deny: string[]; require: string[]; container: boolean };
/** budgets: display only; the hard limits are the keys' daily limit at OpenRouter and 20 minutes per task. */
export type Budgets = { per_task_usd?: number };
export type ClaudeSetting = { model: string; effort: string };
export type Config = {
  classes: Record<string, Class>;
  roles: Record<string, string>;
  rules: Rule[];
  isolationClasses: string[];
  budgets: Budgets;
  /** claude_code.orchestrator; null when the block or the entry is missing. */
  orchestrator: ClaudeSetting | null;
  /** claude_code.subagents: exactly the roles that get a Claude Code agent file. */
  claudeSubagents: Record<string, ClaudeSetting>;
  /** opencode.subagents: exactly the roles that get an OpenCode agent file (unless their class is a placeholder). */
  opencodeSubagents: Record<string, { variant: string | null; steps: number | null }>;
  /** The models.yaml these come from (policyFile). */
  file: string;
};
type Policy = { path: string; match: string; below: string[]; deny_classes: string[]; require: string[]; isolation: "container" | null };

const has = (o: object, k: string) => Object.hasOwn(o, k);
const q = (v: unknown) => JSON.stringify(v) ?? String(v);

// --- models.yaml ------------------------------------------------------------------------------------

const RULE_KEYS = ["match", "deny_classes", "require", "isolation"];
/** Known values of `require`. no-training: the task gets the key of the OpenRouter workspace "clients". */
export const REQUIRE = ["no-training"];
const BUDGET_KEYS = ["per_task_usd"];
/** A misspelt block (`claude-code:`) would otherwise count as missing: nc claude would start without its setting
 * and nc generate would remove every generated file. */
const TOP_KEYS = ["allow_headless_claude", "classes", "roles", "isolation", "policies", "budgets", "claude_code", "opencode"];
export const EFFORTS = ["low", "medium", "high", "xhigh", "max"];
export const ORCHESTRATOR_MODELS = ["opus", "fable"];
export const SUBAGENT_MODELS = ["opus", "sonnet", "haiku", "fable", "inherit"];
/** Role names are file names: lowercase words joined by single hyphens. */
export const ROLE_NAME = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const VARIANT = /^[a-z0-9._-]+$/;

/** The fixed part of a pattern: everything before `/**`. Null for `**`. */
const fixedPart = (match: string) => (match === "**" ? null : match.slice(0, -3));

function validMatch(match: unknown): match is string {
  if (match === "**") return true;
  if (typeof match !== "string" || !match.endsWith("/**")) return false;
  const path = match.slice(0, -3);
  return (path.startsWith("/") || path.startsWith("~/")) && !path.includes("*");
}

/** HOME, which must be absolute: a relative one would read ~ from the current folder, which a project controls. */
export function absHome(): string {
  const home = process.env.HOME ?? "";
  if (!isAbsolute(home)) throw new ModelsError(`HOME is ${home ? "not an absolute path" : "empty"} – without HOME ~ in models.yaml cannot be filled in`);
  return home;
}

/**
 * The models.yaml in force. Isolated: <repo>/models.yaml (nc-work bakes the overlay's copy into the snapshot; the
 * agent owns HOME there). Host: <repo>/models.yaml unless ~/.nc/overlay exists; if it does, its models.yaml must be
 * a regular file. Fail closed: a dangling overlay link or an overlay without models.yaml must never fall back to
 * the public defaults.
 */
export function policyFile(repo: string): string {
  if (mode() === "isolated") return join(repo, "models.yaml");
  const overlay = join(absHome(), ".nc/overlay");
  try {
    lstatSync(overlay);
  } catch (e: any) {
    if (e?.code === "ENOENT") return join(repo, "models.yaml");
    throw new ModelsError(`${overlay} cannot be read (${e?.code ?? e})`);
  }
  const file = join(overlay, "models.yaml");
  let regular: boolean;
  try {
    regular = statSync(file).isFile();
  } catch (e: any) {
    throw new ModelsError(`${file} missing or not readable (${e?.code ?? e}) – an overlay needs its own models.yaml`);
  }
  if (!regular) throw new ModelsError(`${file} is not a regular file`);
  return file;
}

/** Read and check models.yaml. Every deviation throws: a file that is not understood allows nothing. */
export function load(repo: string): Config {
  const file = policyFile(repo);
  const bad = (msg: string): never => {
    throw new ModelsError(`models.yaml: ${msg}`);
  };
  const map = (v: any, what: string): Record<string, any> =>
    v && typeof v === "object" && !Array.isArray(v) ? v : bad(`${what} missing or not a mapping`);
  let text: string;
  try {
    text = readFileSync(file, "utf8");
  } catch (e: any) {
    return bad(`${file} missing or not readable (${e?.code ?? e})`);
  }
  let doc: any;
  try {
    doc = Bun.YAML.parse(text);
  } catch (e: any) {
    return bad(`not valid YAML (${String(e?.message ?? e).split("\n")[0]})`);
  }
  map(doc, "the content");
  const unknownTop = Object.keys(doc).filter((k) => !TOP_KEYS.includes(k));
  if (unknownTop.length) bad(`unknown key ${q(unknownTop[0])} at the top level (allowed: ${TOP_KEYS.join(", ")})`);

  const classes: Record<string, Class> = {};
  for (const [name, c] of Object.entries(map(doc.classes, "classes"))) {
    const { runtime, model } = map(c, `classes.${name}`);
    if (runtime === "claude-code" && model === undefined) classes[name] = { runtime, model: null, placeholder: false };
    else if (runtime === "opencode" && typeof model === "string" && model.startsWith("TODO"))
      classes[name] = { runtime, model, placeholder: true };
    else if (runtime === "opencode" && typeof model === "string" && classify(model).kind !== "invalid")
      classes[name] = { runtime, model, placeholder: false };
    else if (runtime === "opencode" && typeof model === "string")
      bad(`classes.${name}.model ${q(model)} is neither a placeholder (TODO…) nor a model ID of the form openrouter/<author>/<model>`);
    else bad(`classes.${name} needs runtime: claude-code (without model) or runtime: opencode with model`);
  }
  const isClass = (k: unknown): k is string => typeof k === "string" && has(classes, k);
  const classList = (v: unknown, what: string): string[] => {
    if (!Array.isArray(v)) return bad(`${what} is not a list`);
    for (const k of v) if (!isClass(k)) bad(`${what} names ${q(k)}, which is not a class from classes`);
    return v;
  };

  const roles = map(doc.roles ?? {}, "roles");
  for (const [role, k] of Object.entries(roles)) if (!isClass(k)) bad(`roles.${role} names ${q(k)}, which is not a class from classes`);

  if (!Array.isArray(doc.policies)) bad("policies missing or not a list");
  const rules: Rule[] = doc.policies.map((p: any, i: number) => {
    const at = `policies[${i}]`;
    const r = map(p, at);
    const unknown = Object.keys(r).filter((k) => !RULE_KEYS.includes(k));
    if (unknown.length) bad(`${at} has an unknown field ${q(unknown[0])} (allowed: ${RULE_KEYS.join(", ")})`);
    if (!validMatch(r.match)) bad(`${at}.match ${q(r.match)} is neither "**" nor "<path>/**" with a path that starts with / or ~/ and contains no *`);
    if (r.isolation !== undefined && r.isolation !== "container") bad(`${at}.isolation is ${q(r.isolation)}, only container is allowed`);
    const require: unknown[] = r.require === undefined ? [] : Array.isArray(r.require) ? r.require : [r.require];
    for (const v of require) {
      if (typeof v !== "string" || !v) bad(`${at}.require is neither a text nor a list of texts`);
      if (!REQUIRE.includes(v as string)) bad(`${at}.require ${q(v)} is unknown (known: ${REQUIRE.join(", ")})`);
    }
    return {
      match: r.match,
      deny: r.deny_classes === undefined ? [] : classList(r.deny_classes, `${at}.deny_classes`),
      require: [...new Set(require as string[])],
      container: r.isolation === "container",
    };
  });
  const stars = rules.filter((r) => r.match === "**").length;
  if (stars === 0) bad('policies needs match: "**" as its last rule, it is missing');
  if (stars > 1) bad('policies contains match: "**" more than once');
  if (rules.at(-1)!.match !== "**") bad('match: "**" is not the last rule in policies');

  // claude_code and opencode: which agent runs with which model and effort (both blocks may be missing).
  const only = (o: Record<string, any>, keys: string[], at: string) => {
    const unknown = Object.keys(o).filter((k) => !keys.includes(k));
    if (unknown.length) bad(`${at} has an unknown key ${q(unknown[0])} (allowed: ${keys.join(", ")})`);
  };
  const oneOf = (v: unknown, allowed: string[], at: string): string =>
    typeof v === "string" && allowed.includes(v) ? v : bad(`${at} is ${v === undefined ? "not set" : q(v)}, allowed: ${allowed.join(", ")}`);
  const setting = (v: unknown, models: string[], at: string): ClaudeSetting => {
    const s = map(v, at);
    only(s, ["model", "effort"], at);
    return { model: oneOf(s.model, models, `${at}.model`), effort: oneOf(s.effort, EFFORTS, `${at}.effort`) };
  };
  const role = (name: string, at: string) => {
    if (!ROLE_NAME.test(name)) bad(`${at}: ${q(name)} is not a role name (lowercase letters, digits, single hyphens)`);
    if (!has(roles, name)) bad(`${at}: role ${q(name)} is not in roles`);
    let file = false;
    try {
      file = statSync(join(repo, "roles", `${name}.md`)).isFile();
    } catch {}
    if (!file) bad(`${at}: role ${q(name)} has no file roles/${name}.md`);
  };

  let orchestrator: ClaudeSetting | null = null;
  const claudeSubagents: Record<string, ClaudeSetting> = {};
  if (doc.claude_code !== undefined) {
    const cc = map(doc.claude_code, "claude_code");
    only(cc, ["orchestrator", "subagents"], "claude_code");
    if (cc.orchestrator !== undefined) orchestrator = setting(cc.orchestrator, ORCHESTRATOR_MODELS, "claude_code.orchestrator");
    for (const [name, v] of Object.entries(cc.subagents === undefined ? {} : map(cc.subagents, "claude_code.subagents"))) {
      role(name, "claude_code.subagents");
      claudeSubagents[name] = setting(v, SUBAGENT_MODELS, `claude_code.subagents.${name}`);
    }
  }
  const variantOf = (v: unknown, k: string, at: string): string | null => {
    if (v === undefined) return null;
    if (typeof v !== "string" || !VARIANT.test(v)) bad(`${at}.variant ${q(v)} is not made of a-z, 0-9, ., _, - only`);
    if (classes[k].model!.includes("#")) bad(`${at}.variant: the model of class ${k} (${classes[k].model}) already contains a variant (#)`);
    return v as string;
  };
  const opencodeSubagents: Record<string, { variant: string | null; steps: number | null }> = {};
  if (doc.opencode !== undefined) {
    const oc = map(doc.opencode, "opencode");
    only(oc, ["subagents"], "opencode");
    for (const [name, v] of Object.entries(oc.subagents === undefined ? {} : map(oc.subagents, "opencode.subagents"))) {
      const at = `opencode.subagents.${name}`;
      role(name, "opencode.subagents");
      const s = map(v, at);
      only(s, ["variant", "steps"], at);
      const cls = classes[roles[name]];
      if (cls.runtime !== "opencode") bad(`${at}: the role's class ${roles[name]} has runtime: ${cls.runtime}, not opencode`);
      if (s.steps !== undefined && (typeof s.steps !== "number" || !Number.isInteger(s.steps) || s.steps < 1 || s.steps > 500))
        bad(`${at}.steps is ${q(s.steps)}, expected a whole number from 1 to 500`);
      opencodeSubagents[name] = { variant: variantOf(s.variant, roles[name], at), steps: (s.steps as number | undefined) ?? null };
    }
  }

  const iso = doc.isolation === undefined ? {} : map(doc.isolation, "isolation");
  only(iso, ["classes"], "isolation");  // a misspelt `clases` would silently switch isolation.classes off
  const budgets: Budgets = {};
  if (doc.budgets !== undefined) {
    const b = map(doc.budgets, "budgets");
    only(b, BUDGET_KEYS, "budgets");
    if (b.per_task_usd !== undefined) {
      if (typeof b.per_task_usd !== "number" || !Number.isFinite(b.per_task_usd) || b.per_task_usd <= 0)
        bad(`budgets.per_task_usd is ${q(b.per_task_usd)}, expected a number greater than 0 (US dollars)`);
      budgets.per_task_usd = b.per_task_usd;
    }
  }
  return {
    classes,
    roles,
    rules,
    isolationClasses: iso.classes === undefined ? [] : classList(iso.classes, "isolation.classes"),
    budgets,
    orchestrator,
    claudeSubagents,
    opencodeSubagents,
    file,
  };
}

// --- paths ------------------------------------------------------------------------------------------

function exists(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

/**
 * Absolute path with symlinks and `..` resolved by the kernel, so it names the folder a process really ends
 * up in. Parts that do not exist: the nearest existing parent (resolved) plus the rest. A symlink without a
 * target is an error, not a folder that "does not exist yet".
 */
function physical(path: string): string {
  if (!path) throw new ModelsError("path cannot be resolved: empty path");
  // realpath(3), not realpathSync(): that one drops `link/..` as text before it resolves the link. No join() either.
  const real = realpathSync.native;
  let head = isAbsolute(path) ? path : `${real(cwd())}/${path}`;
  const rest: string[] = [];
  for (;;) {
    try {
      return lexical(real(head), ...rest);
    } catch (e: any) {
      if (e?.code !== "ENOENT") throw new ModelsError(`path cannot be resolved (${e?.code ?? e}): ${path}`);
    }
    if (exists(head)) throw new ModelsError(`path cannot be resolved, symlink without a target: ${head}`);
    rest.unshift(basename(head));
    head = dirname(head);
  }
}

/** The real current folder (not $PWD). A deleted one is exit 2, not a stack trace. */
function cwd(): string {
  try {
    return process.cwd();
  } catch (e: any) {
    throw new ModelsError(`current folder cannot be resolved (${e?.code ?? e}) – deleted? Ask with --path or change the folder`);
  }
}

export const PROJECT_PATH = /^[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*\/?$/;

/**
 * The folder asked about and how pattern paths are turned into comparable ones.
 * Direct: real paths on both sides. Isolated: the working folder is /workspace, so the project path comes
 * from NC_PROJECT_PATH (relative to ~/projects) and both sides are compared as text.
 */
function target(o: Opts): { path: string; fixed: (pattern: string) => string } {
  const home = absHome();
  const tilde = (p: string) => (p === "~" ? home : p.startsWith("~/") ? home + p.slice(1) : p);

  if (mode() === "isolated") {
    if (o.path !== undefined || o.host)
      throw new ModelsError("there is no --path or --host in a task container; the project path comes from NC_PROJECT_PATH");
    const value = process.env.NC_PROJECT_PATH;
    if (!value)
      throw new ModelsError("NC_PROJECT_PATH is not set – without it no policy can be determined here. Create a new task with a current nc-work for the policy.");
    if (!PROJECT_PATH.test(value) || value.split("/").some((part) => part === "." || part === ".."))
      throw new ModelsError(`NC_PROJECT_PATH ${q(value)} is not a project path relative to ~/projects (for example clients/acme)`);
    // Both sides as text, both normalised alike: a HOME like /home/agent/ or / must not make them differ.
    return { path: lexical(`${home}/projects/${value}`), fixed: (p) => lexical(tilde(p)) };
  }
  return { path: physical(o.path === undefined ? cwd() : tilde(o.path)), fixed: (p) => physical(tilde(p)) };
}

/** child is parent or lies below it, compared by whole path parts. */
const within = (child: string, parent: string) => parent === "/" || child === parent || child.startsWith(parent + "/");

/**
 * The first matching rule wins. Rules whose folder lies below the asked one add their restrictions: whoever
 * works in ~/projects can reach ~/projects/clients, so the stricter rule must already hold there.
 */
function policyFor(cfg: Config, where: ReturnType<typeof target>): Policy {
  const fixed = cfg.rules.map((r) => (r.match === "**" ? null : where.fixed(fixedPart(r.match)!)));
  const first = cfg.rules.findIndex((_, i) => fixed[i] === null || within(where.path, fixed[i]!));
  const below = cfg.rules.filter((_, i) => i !== first && fixed[i] !== null && fixed[i] !== where.path && within(fixed[i]!, where.path));
  const all = [cfg.rules[first], ...below];
  return {
    path: where.path,
    match: cfg.rules[first].match,
    below: below.map((r) => r.match),
    deny_classes: [...new Set(all.flatMap((r) => r.deny))],
    require: [...new Set(all.flatMap((r) => r.require))],
    isolation: all.some((r) => r.container) ? "container" : null,
  };
}

/** The policy of a folder on the host, as `nc models --path` finds it (nc generate --path). */
export function policyAt(cfg: Config, path: string): Policy {
  return policyFor(cfg, target({ path, json: false, host: false }));
}

const policyName = (p: Policy) => `the policy ${p.match}${p.below.length ? ` (plus from below: ${p.below.join(", ")})` : ""}`;

// --- model IDs --------------------------------------------------------------------------------------

/** An OpenRouter ID that names exactly one model: <author>/<model>[:suffix…]. */
const CLEAR_ID = /^[a-z0-9._-]+\/[a-z0-9._-]+(:[a-z0-9._-]+)*$/;
/** IDs of a clear form that still do not name the model: OpenRouter's own (author `openrouter`) and these routers. */
const ROUTERS = ["nvidia/switchyard", "typesafe/jev-router"];

/**
 * What a model ID is, in the form OpenCode gets it: openrouter/<OpenRouter ID>[#variant]. The one place for
 * these rules.
 *   invalid  empty or not an OpenRouter model – refused everywhere
 *   free     one of the suffixes is `free`
 *   router   the ID does not decide the model: a router, or anything not of the clear form (alias, preset, typo)
 *   paid     everything else
 */
export function classify(raw: string): { id: string; kind: "invalid" | "free" | "router" | "paid" } {
  const id = raw.split("#")[0];
  const or = id.startsWith("openrouter/") ? id.slice("openrouter/".length) : "";
  if (!or) return { id, kind: "invalid" };
  if (!CLEAR_ID.test(or)) return { id, kind: "router" };
  const [base, ...suffixes] = or.split(":");
  if (base.startsWith("openrouter/") || ROUTERS.includes(base)) return { id, kind: "router" };
  return { id, kind: suffixes.includes("free") ? "free" : "paid" };
}

/** Why this model is refused in the folder of this policy, or null. */
function modelRefusal(cfg: Config, pol: Policy, raw: string): string | null {
  const { id, kind } = classify(raw);
  if (kind === "invalid") return `${q(raw)} is not a model ID of the form openrouter/<author>/<model>`;
  if (pol.deny_classes.includes("free") && kind !== "paid")
    return `${q(id)} is ${kind === "free" ? "a free model" : "a router or alias (the ID does not fix the model)"}, and ${policyName(pol)} denies the class free in ${pol.path}`;
  const denied = pol.deny_classes.find((k) => cfg.classes[k].model?.split("#")[0] === id);
  if (denied) return `${q(id)} is the model of class ${denied}, and ${policyName(pol)} denies it in ${pol.path}`;
  if (pol.deny_classes.includes("free") || pol.require.length) {
    // Built from cfg.classes directly, not through classStatus (that one calls this function). Exact comparison:
    // no case folding, no suffix stripped – ":nitro" on an allowed model is another model.
    const allowed = Object.entries(cfg.classes).filter(([k, c]) => !pol.deny_classes.includes(k) && !c.placeholder && c.model !== null);
    if (!allowed.some(([, c]) => c.model!.split("#")[0] === id)) {
      const list = allowed.map(([k, c]) => `${k}: ${c.model!.split("#")[0]}`).join(", ") || "none";
      return `${q(id)} is not approved: in ${pol.path} only the models of the allowed classes apply (${list}). A new model goes into classes and into the guardrail of clients first.`;
    }
  }
  return null;
}

/**
 * A class in this folder. The policy comes first, then the placeholder, then the model itself. isolation:
 * "container" when the policy asks for it or the class is in isolation.classes (then a worker of this class runs
 * only in a container, nc delegate; OpenCode on the host is not affected).
 */
export function classStatus(cfg: Config, pol: Policy, name: string) {
  const c = cfg.classes[name];
  let reason: string | null = null;
  if (pol.deny_classes.includes(name)) reason = `${policyName(pol)} denies the class ${name}`;
  else if (c.placeholder) reason = "the model is a placeholder (TODO in models.yaml)";
  else if (c.model !== null) reason = modelRefusal(cfg, pol, c.model);
  const isolation: "container" | null = pol.isolation ?? (cfg.isolationClasses.includes(name) ? "container" : null);
  return { runtime: c.runtime, model: c.placeholder ? null : c.model, allowed: reason === null, reason, isolation };
}

// --- commands ---------------------------------------------------------------------------------------

type Opts = { path?: string; model?: string; class?: string; role?: string; json: boolean; host: boolean };

function parse(args: string[], allowed: string[]): Opts {
  const o: any = { json: false, host: false };
  for (let i = 0; i < args.length; i++) {
    const m = args[i].match(/^--(path|model|class|role|json|host)(?:=(.*))?$/s);
    if (!m || !allowed.includes(m[1])) throw new ModelsError(`unknown option or argument ${q(args[i])} (nc models help)`);
    const key = m[1];
    if (key === "json" || key === "host") {
      if (m[2] !== undefined) throw new ModelsError(`--${key} takes no value`);
      o[key] = true;
      continue;
    }
    if (o[key] !== undefined) throw new ModelsError(`--${key} given more than once`);
    const value = m[2] ?? args[++i];
    if (value === undefined) throw new ModelsError(`--${key} needs a value`);
    o[key] = value;
  }
  return o;
}

const HELP = `nc models – what models.yaml allows in a folder

  nc models [--path DIR] [--json]
        the folder's policy; per class runtime, model, whether it is allowed there and whether only in a container; budgets
  nc models resolve (--class K | --role R) [--path DIR] [--json]
        one line: "opencode openrouter/<author>/<model>" or "claude-code". Never another class instead.
        --json adds isolation ("container": workers only in a container) and the policy's require
  nc models check [--model ID] [--path DIR] [--host]
        exit 0 only if the model (openrouter/<author>/<model>[#variant]) is allowed there;
        with --host also only if OpenCode may start directly on the host in that folder
  nc models orchestrator
        one line "<model> <effort>" from claude_code.orchestrator (for nc claude); exit 1 if it is not set.
        Without a policy and without a folder, the same in both modes

Exit 0 allowed, 1 refused, 2 error; the reason is on stderr. Without --path the current folder applies.
In a task container the project path comes from NC_PROJECT_PATH; there is no --path or --host there.
Where the policy denies free or sets require, check allows exactly the models of the classes allowed there.
Otherwise check knows no catalog: it does not recognize a free model without ":free" in its ID.
`;

function show(cfg: Config, pol: Policy, o: Opts): number {
  const classes = Object.fromEntries(Object.keys(cfg.classes).map((k) => [k, classStatus(cfg, pol, k)]));
  if (o.json) {
    const { path, ...policy } = pol;
    console.log(JSON.stringify({ path, file: cfg.file, policy, classes, roles: cfg.roles, isolation: { classes: cfg.isolationClasses }, budgets: cfg.budgets }, null, 2));
    return 0;
  }
  const list = (v: string[]) => v.join(", ") || "–";
  const pad = (rows: string[][]) => rows.map((r) => "  " + r.map((c, i) => (i < r.length - 1 ? c.padEnd(Math.max(...rows.map((x) => x[i].length))) : c)).join("  ").trimEnd());
  const lines = [
    `nc models – ${pol.path}`,
    `policy file: ${cfg.file}`,
    "",
    `policy: ${pol.match}`,
    ...pad([
      ...(pol.below.length ? [["plus from below", pol.below.join(", ")]] : []),
      ["denied classes", list(pol.deny_classes)],
      ["require", list(pol.require)],
      ["isolation", pol.isolation ?? "–"],
    ]),
    "",
    "classes:",
    ...pad(
      Object.entries(classes).map(([k, s]) => [
        k,
        s.runtime,
        s.model ?? (s.runtime === "opencode" ? "not set" : "–"),
        (s.allowed ? "allowed" : `denied: ${s.reason}`) + (s.isolation ? " · only in a container" : ""),
      ]),
    ),
    "",
    "roles:",
    ...pad(Object.entries(cfg.roles).map(([r, k]) => [r, k])),
    "",
    `isolation.classes: ${list(cfg.isolationClasses)} (workers of these classes only in a container)`,
    `budgets: ${list(Object.entries(cfg.budgets).map(([k, v]) => `${k} ${v}`))} (display only, hard limit: daily limit at OpenRouter and 20 minutes per task)`,
  ];
  console.log(lines.join("\n"));
  return 0;
}

function resolveCmd(cfg: Config, pol: Policy, o: Opts): number {
  if ((o.class === undefined) === (o.role === undefined)) throw new ModelsError("resolve needs exactly one of --class K and --role R");
  if (o.role !== undefined && !has(cfg.roles, o.role)) throw new ModelsError(`unknown role ${q(o.role)} (roles in models.yaml: ${Object.keys(cfg.roles).join(", ")})`);
  const name = o.role !== undefined ? cfg.roles[o.role] : o.class!;
  if (!has(cfg.classes, name)) throw new ModelsError(`unknown class ${q(name)} (classes in models.yaml: ${Object.keys(cfg.classes).join(", ")})`);
  const s = classStatus(cfg, pol, name);
  const what = `class ${name}${o.role !== undefined ? ` (role ${o.role})` : ""}`;
  if (!s.allowed) throw new Refused(`${what} in ${pol.path}: ${s.reason}. No other class instead.`);
  if (o.json) console.log(JSON.stringify({ class: name, role: o.role ?? null, runtime: s.runtime, model: s.model, isolation: s.isolation, require: pol.require }));
  else console.log(s.model === null ? s.runtime : `${s.runtime} ${s.model}`);
  return 0;
}

function check(cfg: Config, pol: Policy, o: Opts): number {
  const reasons: string[] = [];
  if (o.host && pol.isolation)
    reasons.push(
      `${policyName(pol)} requires isolation: container for ${pol.path}. ` +
        (Bun.which("nc-work")
          ? "OpenCode does not start there directly on the host but in a container: nc-work here --runtime opencode"
          : "In this folder OpenCode runs only in a container, and this machine has none (nc-work missing)."),
    );
  const model = o.model === undefined ? null : modelRefusal(cfg, pol, o.model);
  if (model) reasons.push(model);
  if (reasons.length) throw new Refused(reasons.join("\nnc models: "));
  return 0;  // allowed: nothing on stdout, so a caller can pass the output of what it starts straight through
}

export function models(repo: string, args: string[]): number {
  try {
    const sub = args[0] === undefined || args[0].startsWith("--") ? undefined : args[0];
    const rest = sub === undefined ? args : args.slice(1);
    if (sub === "help" || args[0] === "-h" || args[0] === "--help") {
      process.stdout.write(HELP);
      return 0;
    }
    const run = (o: Opts, cmd: (cfg: Config, pol: Policy, o: Opts) => number) => {
      const cfg = load(repo);
      return cmd(cfg, policyFor(cfg, target(o)), o);
    };
    switch (sub) {
      case undefined:
        return run(parse(rest, ["path", "json"]), show);
      case "resolve":
        return run(parse(rest, ["class", "role", "path", "json"]), resolveCmd);
      case "orchestrator": {
        if (rest.length) throw new ModelsError(`orchestrator takes no arguments, not ${q(rest[0])}`);
        const o = load(repo).orchestrator;
        if (!o) throw new Refused("claude_code.orchestrator is not set in models.yaml");
        console.log(`${o.model} ${o.effort}`);
        return 0;
      }
      case "check": {
        const o = parse(rest, ["model", "path", "host"]);
        if (o.model === undefined && !o.host) throw new ModelsError("check asks nothing: give --model ID or --host");
        return run(o, check);
      }
      default:
        throw new ModelsError(`unknown command ${q(sub)} (nc models help)`);
    }
  } catch (e: any) {
    // Exit 1 means "asked correctly, the answer is no". Anything unexpected is an error (exit 2), never that.
    const message = e instanceof ModelsError || e instanceof Refused ? e.message : `unexpected error: ${e?.message ?? e}`;
    process.stderr.write(`nc models: ${message}\n`);
    return e instanceof Refused ? 1 : 2;
  }
}

// --- nc doctor (direct only) -------------------------------------------------------------------------

type Check = { name: string; status: "ok" | "warn" | "fail"; detail: string };

/** models.yaml passes the checks of load(); classes whose model is still a placeholder are a warning. */
export function modelsChecks(repo: string): Check[] {
  let cfg: Config;
  try {
    cfg = load(repo);
  } catch (e) {
    if (!(e instanceof ModelsError)) throw e;
    return [{ name: "models.yaml", status: "fail", detail: e.message.replace(/^models\.yaml: /, "") }];
  }
  const todo = Object.keys(cfg.classes).filter((k) => cfg.classes[k].placeholder);
  const checks: Check[] = [{ name: "models.yaml", status: "ok", detail: `${Object.keys(cfg.classes).length} classes, ${cfg.rules.length} policies (${cfg.file})` }];
  if (todo.length) checks.push({ name: "models", status: "warn", detail: `placeholder instead of a model in ${todo.join(", ")} – nc models resolve refuses these classes` });
  return checks;
}

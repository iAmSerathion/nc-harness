import { accessSync, constants, existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { join } from "node:path";
import { delegateCheckIsolated } from "./delegate.ts";
import { agentChecks, agentChecksIsolated, claudeEnvChecks, mcpChecks } from "./generate.ts";
import { HooksError, hookState, parseSettings, readSettings } from "./hooks.ts";
import { expandSkills, readManifest, staleSkillLinks } from "./manifest.ts";
import { memoryChecksDirect, memoryChecksIsolated } from "./memory.ts";
import { commit, machine, mode, ncHome, opencodeConfigDir } from "./mode.ts";
import { ModelsError, modelsChecks, policyFile } from "./models.ts";

type Status = "ok" | "warn" | "fail";
type Check = { name: string; status: Status; detail: string };

function lstat(path: string) {
  try {
    return lstatSync(path);
  } catch {
    return null;
  }
}

function real(path: string): string | null {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
}

function isDir(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

const truthy = (v: string | undefined) => ["1", "true"].includes((v ?? "").toLowerCase());

function version(bin: string): string {
  const r = Bun.spawnSync([bin, "--version"], { stdout: "pipe", stderr: "pipe", timeout: 10_000 });
  return r.success ? r.stdout.toString().trim().split("\n")[0] : "version unknown";
}

/** A tool on PATH. `missing` decides how bad its absence is. */
function tool(bin: string, missing: Status, hint: string): Check {
  const path = Bun.which(bin);
  if (!path) return { name: bin, status: missing, detail: `not found – ${hint}` };
  return { name: bin, status: "ok", detail: version(bin) };
}

/** A command that must exit 0. Missing or failing only warns: these need network or a daemon. */
function succeeds(name: string, cmd: string[], hint: string): Check {
  if (!Bun.which(cmd[0])) return { name, status: "warn", detail: `${cmd[0]} not found – ${hint}` };
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe", timeout: 15_000 });
  return r.success
    ? { name, status: "ok", detail: r.stdout.toString().trim().split("\n")[0] || "yes" }
    : { name, status: "warn", detail: `no – ${hint}` };
}

/**
 * A key in secrets.env (OPENROUTER_API_KEY or OPENROUTER_API_KEY_CLIENTS), by the same rule as cli/opencode.sh and
 * nc-work: the whole name before "=", so neither line counts for the other; trim the line (BOM, CR,
 * ASCII whitespace), optional `export `, trim the value, strip one pair of matching quotes, last line wins; the
 * value must be printable ASCII without spaces. Returns "missing", "invalid" or "ok". Never returns the value.
 */
export function keyState(text: string, name = "OPENROUTER_API_KEY"): "missing" | "invalid" | "ok" {
  const pattern = new RegExp(`^(?:export[ \\t\\v\\f]+)?${name}=(.*)$`);
  let value: string | null = null;
  for (const raw of text.split("\n")) {
    const line = asciiTrim(raw.replace(/^\uFEFF/, "").replaceAll("\r", ""));
    const m = line.match(pattern);
    if (!m) continue;
    let v = asciiTrim(m[1]);
    if (v.length >= 2 && (v[0] === '"' || v[0] === "'") && v.at(-1) === v[0]) v = v.slice(1, -1);
    value = v;
  }
  if (!value) return "missing";
  return /^[\x21-\x7e]+$/.test(value) ? "ok" : "invalid";
}

const asciiTrim = (s: string) => s.replace(/^[ \t\n\v\f\r]+|[ \t\n\v\f\r]+$/g, "");

/** opencode.json and service.json where OpenCode really looks resolve to the harness' files. */
function opencodeConfigActive(repo: string, home: string, tilde: (p: string) => string): Check {
  const dir = opencodeConfigDir(home);
  const off = ["opencode.json", "service.json"].filter((f) => real(join(dir, f)) !== real(join(repo, "adapters/opencode", f)));
  return off.length
    ? { name: "OpenCode configuration", status: "fail", detail: `OpenCode reads ${tilde(dir)}, the harness' ${off.join(", ")} is missing there – otherwise the background service starts with the key` }
    : { name: "OpenCode configuration", status: "ok", detail: tilde(dir) };
}

/** Pinned version of a tool for this platform (pins.txt). */
export function pinned(repo: string, toolName: string): string | null {
  const os = process.platform === "darwin" ? "darwin" : process.platform === "linux" ? "linux" : null;
  const arch = process.arch === "x64" ? "x64" : process.arch === "arm64" ? "arm64" : null;
  if (!os || !arch) return null;
  for (const raw of readFileSync(join(repo, "pins.txt"), "utf8").split("\n")) {
    const [t, v, platform] = raw.trim().split(/\s+/);
    if (t === toolName && platform === `${os}-${arch}`) return v;
  }
  return null;
}

/** OpenCode on PATH in the pinned version. Missing fails (it is one of the two runtimes), unless pins.txt has no
 * version for this platform yet: then install.sh cannot help and it only warns. Direct mode (`pinnedPath`) also
 * checks that the opencode on PATH is the file install.sh put under ~/.nc/opencode/<version>/: a copy of the same
 * version elsewhere (the official installer's ~/.opencode/bin before ~/.local/bin) is not pinned, and nc opencode
 * would start it. A failure on the Mac, where that copy exists; a warning on the server. In a container OpenCode
 * comes from the image: no path check there. */
function opencode(repo: string, hint: string, pinnedPath?: { home: string; mac: boolean; tilde: (p: string) => string }): Check {
  const want = pinned(repo, "opencode");
  const path = Bun.which("opencode");
  if (!path && !want) return { name: "opencode", status: "warn", detail: "not found, no version for this platform in pins.txt" };
  if (!path) return { name: "opencode", status: "fail", detail: `not found – ${hint}` };
  const got = version("opencode").match(/\d+\.\d+\.\d+/)?.[0] ?? "unknown";
  if (!want) return { name: "opencode", status: "warn", detail: `${got}, no version for this platform in pins.txt` };
  if (got !== want) return { name: "opencode", status: "warn", detail: `${got}, pinned is ${want} – ${hint}` };
  if (pinnedPath) {
    const bin = join(ncHome(pinnedPath.home), "opencode", want, "opencode");
    const found = real(path);
    if (!found || found !== real(bin))
      return { name: "opencode", status: pinnedPath.mac ? "fail" : "warn", detail: `another opencode before ~/.local/bin on PATH: ${pinnedPath.tilde(path)} (pinned: ${pinnedPath.tilde(bin)})` };
  }
  return { name: "opencode", status: "ok", detail: got };
}

/** OpenCode 2 reads ~/.claude/skills unless one of these is set (server-process.ts, 2.2.7). */
function opencodeReadsClaudeSkills(): Check {
  const off = ["OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS"].filter((k) => truthy(process.env[k]));
  return off.length
    ? { name: "skills for OpenCode", status: "warn", detail: `${off.join(", ")} set – OpenCode does not read ~/.claude/skills` }
    : { name: "skills for OpenCode", status: "ok", detail: "through ~/.claude/skills" };
}

const KEY_CLIENTS = "OPENROUTER_API_KEY_CLIENTS";

/** Presence of OPENROUTER_API_KEY and OPENROUTER_API_KEY_CLIENTS in secrets.env. Reads the file, never prints a value.
 * On the Mac the clients key is not needed (only nc-work reads it): missing is ok there. */
function secretsFile(path: string, tilde: (p: string) => string, mac: boolean): Check[] {
  const name = tilde(path);
  const st = lstat(path);
  if (!st) return [{ name, status: "fail", detail: "missing – ./install.sh creates a template" }];
  if (!st.isFile()) return [{ name, status: "fail", detail: "not a regular file" }];
  const checks: Check[] = [];
  const perm = st.mode & 0o777;
  checks.push(
    perm & 0o077
      ? { name, status: "fail", detail: `permissions ${perm.toString(8)}, expected 600 – chmod 600 ${name}` }
      : { name, status: "ok", detail: `permissions ${perm.toString(8)}` },
  );
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return [...checks, { name: "OPENROUTER_API_KEY", status: "fail", detail: "secrets.env not readable" }];
  }
  const invalid = `invalid in ${name} (space or comment in the value)`;
  const line = (key: string, state: ReturnType<typeof keyState>, missing: string): Check =>
    state === "ok"
      ? { name: key, status: "ok", detail: "present in secrets.env" }
      : state === "invalid"
        ? { name: key, status: "fail", detail: invalid }
        : { name: key, status: "warn", detail: missing };
  checks.push(line("OPENROUTER_API_KEY", keyState(text, "OPENROUTER_API_KEY"), `missing or empty in ${name} – add it yourself`));
  // The second key: nc-work gives it to tasks whose project denies the class free (client code), never the first one.
  const clients = keyState(text, KEY_CLIENTS);
  if (clients !== "missing") checks.push(line(KEY_CLIENTS, clients, ""));
  else if (mac) checks.push({ name: KEY_CLIENTS, status: "ok", detail: "only for nc-work, not needed on the Mac" });
  else checks.push({ name: KEY_CLIENTS, status: "warn", detail: "missing – OpenCode does not start in client tasks" });
  return checks;
}

/** ~/.nc/overlay: which of its files are in force, or why nc models refuses it (policyFile is the one rule). */
function overlayCheck(repo: string, home: string, tilde: (p: string) => string): Check {
  const dir = join(home, ".nc/overlay");
  if (!lstat(dir)) return { name: "overlay", status: "ok", detail: "none – public defaults" };
  try {
    policyFile(repo);
  } catch (e) {
    if (!(e instanceof ModelsError)) throw e;
    return { name: "overlay", status: "fail", detail: `broken – ${e.message}` };
  }
  const files = ["AGENTS.md", "models.yaml"].filter((f) => existsSync(join(dir, f)));
  return { name: "overlay", status: "ok", detail: `${tilde(dir)}: ${files.join(", ")}` };
}

/** The harness's Claude Code hook (nc hooks): a warning when it is missing, since only the restore after a
 * compaction depends on it. */
function claudeHookCheck(home: string): Check {
  const name = "Claude Code compact hook";
  try {
    const state = hookState(parseSettings(readSettings(home).text));
    return state === "ok"
      ? { name, status: "ok", detail: "SessionStart compact runs nc orchestrator status context" }
      : { name, status: "warn", detail: `${state} – nc hooks (or ./install.sh)` };
  } catch (e: any) {
    return { name, status: "warn", detail: `~/.claude/settings.json: ${e instanceof HooksError ? e.message : e?.code ?? e?.message ?? e}` };
  }
}

const ISOLATION_SERVER_ONLY = "isolation only on the server";

function directChecks(repo: string, home: string, tilde: (p: string) => string): Check[] {
  const checks: Check[] = [];

  for (const e of readManifest(repo, home)) {
    if (e.kind === "dir") {
      const ok = isDir(e.target);
      checks.push({ name: tilde(e.target) + "/", status: ok ? "ok" : "fail", detail: ok ? "present" : "missing – ./install.sh" });
      continue;
    }
    if (e.kind === "skills" && lstat(e.target)?.isSymbolicLink()) {
      // install.sh refuses here: linking into it could move skills out of the repo.
      checks.push({ name: tilde(e.target), status: "fail", detail: "is a link itself – remove it by hand, then ./install.sh" });
      continue;
    }
    const links = e.kind === "skills" ? expandSkills(e) : [e];
    if (e.kind === "skills" && links.length === 0)
      checks.push({ name: tilde(e.target) + "/", status: "warn", detail: `no skills in ${tilde(e.source)}` });
    for (const l of links) {
      const st = lstat(l.target);
      let status: Status = "fail";
      let detail: string;
      if (!st) detail = "missing – ./install.sh";
      else if (!st.isSymbolicLink()) detail = "not a link – ./install.sh backs it up and links it";
      else if (readlinkSync(l.target) !== l.source) detail = `points to ${readlinkSync(l.target)}`;
      else if (!lstat(l.source)) detail = `target ${tilde(l.source)} missing`;
      else {
        status = "ok";
        detail = "-> " + tilde(l.source);
      }
      checks.push({ name: tilde(l.target), status, detail });
    }
    if (e.kind === "skills") {
      for (const s of staleSkillLinks(e))
        checks.push({ name: tilde(s), status: "warn", detail: "skill no longer in the repo – ./install.sh removes the link" });
    }
  }

  const ncOnPath = Bun.which("nc");
  checks.push(
    ncOnPath === join(home, ".local/bin/nc")
      ? { name: "nc on PATH", status: "ok", detail: tilde(ncOnPath) }
      : { name: "nc on PATH", status: "warn", detail: ncOnPath ? `another nc: ${ncOnPath}` : "~/.local/bin missing from PATH" },
  );

  // Machine prerequisites. The harness checks them, it does not install them. On the Mac there is no
  // isolation: no nc-work, Docker for tasks or nc delegate; Bun may come from Homebrew, Node from fnm.
  let mac = false;
  try {
    mac = machine() === "mac";
  } catch (e) {
    if (!(e instanceof ModelsError)) throw e;
    checks.push({ name: "machine", status: "fail", detail: e.message });
  }
  const projects = join(home, "projects");
  const hasProjects = isDir(projects);
  checks.push({ name: "~/projects/", status: hasProjects ? "ok" : "fail", detail: hasProjects ? "present" : "missing – set up the machine" });
  checks.push(tool("git", "fail", "set up the machine"));
  checks.push(tool("gh", "fail", "set up the machine"));
  checks.push(succeeds("gh logged in", ["gh", "auth", "status"], "gh auth login"));
  checks.push(
    mac && !Bun.which("mise") && Bun.which("bun")
      ? { name: "mise", status: "ok", detail: "not needed – Bun from Homebrew" }
      : tool("mise", "warn", "set up the machine"),
  );
  checks.push({ name: "bun", status: "ok", detail: Bun.version });
  checks.push(mac ? tool("node", "warn", "nothing in the harness needs Node (Mac: fnm)") : tool("node", "fail", "set up the machine (mise)"));
  checks.push(tool("claude", "fail", "install Claude Code"));
  checks.push(opencode(repo, "./install.sh", { home, mac, tilde }));
  checks.push(opencodeConfigActive(repo, home, tilde));
  checks.push(opencodeReadsClaudeSkills());
  checks.push(tool("hc", "fail", "install herdr-core"));
  // nc memory locks ~/.nc/memory with flock(1) and writes without a lock when it is missing (cli/memory.ts).
  checks.push(tool("flock", "warn", "nc memory writes without a lock (Mac: brew install flock)"));
  const ncWork = Bun.which("nc-work");
  if (mac) {
    checks.push({ name: "docker without sudo", status: "ok", detail: ISOLATION_SERVER_ONLY });
    checks.push(
      ncWork
        ? { name: "nc-work", status: "warn", detail: `nc-work on the Mac – the harness plans no isolation here (${tilde(ncWork)})` }
        : { name: "nc-work", status: "ok", detail: ISOLATION_SERVER_ONLY },
    );
    checks.push({ name: "nc delegate", status: "ok", detail: ISOLATION_SERVER_ONLY });
  } else {
    checks.push(succeeds("docker without sudo", ["docker", "info", "--format", "{{.ServerVersion}}"], "needed only for worker sandboxes"));
    checks.push(
      ncWork
        ? { name: "nc-work", status: "ok", detail: tilde(ncWork) }
        : { name: "nc-work", status: "warn", detail: "not found – needed only on servers (nc-infra)" },
    );
    const delegateMissing = ["nc-work", "hc"].filter((b) => !Bun.which(b));
    checks.push(
      delegateMissing.length
        ? { name: "nc delegate", status: "warn", detail: `${delegateMissing.join(" and ")} not found – nc delegate refuses (workers need nc-work and hc)` }
        : { name: "nc delegate", status: "ok", detail: "nc-work and hc found" },
    );
  }

  // Shared memory.
  checks.push(...memoryChecksDirect(home));

  // Model classes and policies: a models.yaml that is not understood allows nothing.
  checks.push(overlayCheck(repo, home, tilde));
  checks.push(...modelsChecks(repo));

  // Subagent files from roles/ and models.yaml and variables that override them.
  checks.push(...agentChecks(repo, home));
  checks.push(...claudeEnvChecks());
  checks.push(claudeHookCheck(home));

  // MCP files from mcp/servers.yaml, host only.
  checks.push(...mcpChecks(repo, home));

  // Keys: only whether they are there, never the value.
  checks.push(...secretsFile(join(home, ".config/nc-harness/secrets.env"), tilde, mac));
  if (process.env.OPENROUTER_API_KEY)
    checks.push(
      process.env.NC_OPENCODE
        ? { name: "OPENROUTER_API_KEY in the shell", status: "ok", detail: "from nc opencode, for this session only" }
        : { name: "OPENROUTER_API_KEY in the shell", status: "warn", detail: "exported – every agent inherits it; load it only through nc opencode" },
    );

  return checks;
}

/** Inside an nc-work container: the harness is a read-only snapshot, nc-infra's entry script made the links. */
function isolatedChecks(repo: string, home: string, tilde: (p: string) => string): Check[] {
  const checks: Check[] = [];

  let readOnly = false;
  try {
    accessSync(repo, constants.W_OK);
  } catch {
    readOnly = true;
  }
  checks.push(
    readOnly
      ? { name: `harness ${repo}`, status: "ok", detail: `read-only, commit ${commit(repo)}` }
      : { name: `harness ${repo}`, status: "warn", detail: "writable – nc-work otherwise mounts it read-only" },
  );

  // Same manifest, but only what must hold in a container: every link resolves to the snapshot's file.
  // nc-work links ~/.claude/skills as a whole, so compare resolved paths, not link text.
  for (const e of readManifest(repo, home)) {
    if (e.kind === "dir") continue;
    for (const l of e.kind === "skills" ? expandSkills(e) : [e]) {
      const got = real(l.target);
      const want = real(l.source);
      checks.push(
        got && got === want
          ? { name: tilde(l.target), status: "ok", detail: "-> " + l.source }
          : { name: tilde(l.target), status: "fail", detail: got ? `points to ${got}` : "missing – start script of nc-work (nc-infra)" },
      );
    }
  }

  const ncOnPath = Bun.which("nc");
  const ncOk = ncOnPath && real(ncOnPath) === real(join(repo, "bin/nc"));
  checks.push({ name: "nc on PATH", status: ncOk ? "ok" : "fail", detail: ncOnPath ? tilde(ncOnPath) : "missing" });

  checks.push(tool("git", "fail", "belongs in the image (nc-infra)"));
  checks.push({ name: "bun", status: "ok", detail: Bun.version });
  checks.push(tool("node", "fail", "belongs in the image (nc-infra)"));
  checks.push(tool("claude", "fail", "belongs in the image (nc-infra)"));
  checks.push(opencode(repo, "belongs in the image (nc-infra), same version as pins.txt"));
  checks.push(opencodeConfigActive(repo, home, tilde));
  checks.push(opencodeReadsClaudeSkills());

  // Memory: a read-only view of the own project and a writable outbox, both from nc-work.
  checks.push(...memoryChecksIsolated());

  // Subagents: two read-only folders nc-work fills on the host before every session start.
  checks.push(...agentChecksIsolated());
  checks.push({ name: "MCP", status: "ok", detail: "no MCP servers in the container" });

  // nc delegate: mailbox and inbox from nc-work, heartbeat of the broker on the host. Warnings only.
  checks.push(delegateCheckIsolated());

  // Keys: the container never gets secrets.env, and no key at all: nc-work opencode gives OpenCode the
  // placeholder nc-keyproxy, the key goes on stdin into the run's own key proxy. Never prints a value.
  const secrets = join(home, ".config/nc-harness/secrets.env");
  checks.push(
    existsSync(secrets)
      ? { name: "secrets.env", status: "fail", detail: `${tilde(secrets)} is in the container – it belongs on the host only` }
      : { name: "secrets.env", status: "ok", detail: "not in the container" },
  );
  checks.push(keyCheckIsolated(process.env.OPENROUTER_API_KEY));
  return checks;
}

/** OPENROUTER_API_KEY in a task container: the key proxy's placeholder, unset, or (warning) a real value from the old way. */
export function keyCheckIsolated(value: string | undefined): Check {
  const name = "OPENROUTER_API_KEY";
  if (value === "nc-keyproxy") return { name, status: "ok", detail: "placeholder, key in the proxy" };
  if (value) return { name, status: "warn", detail: "real value in the container (old way?) – nc-work opencode gives only the placeholder; start the run again" };
  return { name, status: "warn", detail: "not set – needed only for OpenCode, start with nc-work opencode" };
}

export function runChecks(repo: string, home: string): Check[] {
  const tilde = (p: string) => (p.startsWith(home + "/") || p === home ? "~" + p.slice(home.length) : p);
  return mode() === "isolated" ? isolatedChecks(repo, home, tilde) : directChecks(repo, home, tilde);
}

export function doctor(repo: string, home: string, args: string[]): number {
  const checks = runChecks(repo, home);
  const failed = checks.filter((c) => c.status === "fail").length;
  const warned = checks.filter((c) => c.status === "warn").length;
  const m = mode();

  if (args.includes("--json")) {
    console.log(JSON.stringify({ ok: failed === 0, mode: m, harness: commit(repo), failed, warned, checks }, null, 2));
  } else {
    const mark = { ok: "✓", warn: "!", fail: "✗" };
    console.log(`nc doctor (${m}, harness ${commit(repo)})`);
    for (const c of checks) console.log(`  ${mark[c.status]} ${c.name.padEnd(34)} ${c.detail}`);
    const hints = `${warned} ${warned === 1 ? "note" : "notes"}`;
    console.log(failed ? `\n${failed} ${failed === 1 ? "failure" : "failures"}, ${hints}` : `\nall green (${hints})`);
  }
  return failed ? 1 : 0;
}

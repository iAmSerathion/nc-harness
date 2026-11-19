/**
 * mcp/servers.yaml – MCP servers, defined once. ~/.nc/overlay/mcp/servers.yaml wins when it exists (private servers,
 * workspace ids and the like stay out of the public repo); otherwise <repo>/mcp/servers.yaml. Read and checked here, written by nc generate on the
 * host only (never with --out: no MCP in task containers).
 *
 *   servers:
 *     <name>:                      # form of a role name
 *       type: local | remote
 *       command: [prog, arg, …]    # local only: a non-empty list of texts
 *       env: { NAME: "text" }      # local only, optional: values are YAML texts
 *       url: https://…             # remote only: Streamable HTTP; http only for localhost, 127.0.0.1 and [::1]
 *       headers: { Name: "text" }  # remote only, optional; values may hold ${NC_MCP_…} references, nothing else secret
 *       machines: [server, mac]    # required; only servers that name machine() are used
 *
 * Every deviation is exit 2. `${`, `{env:` and `{file:` in any text of an entry are refused (both runtimes would
 * substitute them themselves, and under nc opencode the OpenRouter key is in the environment), and so is an env name
 * that starts with OPENROUTER_API_KEY. The one exception: ${NC_MCP_NAME} in a header value. nc claude exports the
 * NC_MCP_* lines of secrets.env (and only those) and Claude Code substitutes them in headers (checked with 2.1.327),
 * so the secret never lands in the repo or in ~/.nc/mcp. OpenCode gets no remote server with headers (nc opencode does
 * not export NC_MCP_*). Limits: an exported NC_MCP_* value is in Claude's environment, so its Bash tool, hooks and
 * local MCP servers can read it (nc claude exports only the names claude.json references); a local server started by
 * OpenCode under nc opencode inherits its environment, OPENROUTER_API_KEY included.
 */
import { lstatSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { machine } from "./mode.ts";
import { absHome, ModelsError, ROLE_NAME } from "./models.ts";

export type McpServer =
  | { name: string; type: "local"; command: string[]; env: Record<string, string> | null; machines: string[] }
  | { name: string; type: "remote"; url: string; headers: Record<string, string> | null; machines: string[] };

export const MCP_FILE = "mcp/servers.yaml";
const MACHINES = ["server", "mac"];
const SECRET = /\$\{|\{env:|\{file:/;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const HEADER_NAME = /^[A-Za-z0-9-]+$/;
const SECRET_REF = /\$\{NC_MCP_[A-Z0-9_]+\}/g;   // the only reference allowed, and only in a header value
const LOCAL_HOSTS = ["localhost", "127.0.0.1", "[::1]"];
const q = (v: unknown) => JSON.stringify(v) ?? String(v);

/** The servers.yaml in force: the overlay's when ~/.nc/overlay/mcp/servers.yaml exists, else the repo's. MCP is host
 * only, so no isolated case. Something there that is not a regular file is an error, never a silent fallback. */
export function mcpFile(repo: string): { path: string; label: string } {
  const dir = join(absHome(), ".nc/overlay", "mcp");
  const file = join(dir, "servers.yaml");
  for (const p of [dir, file]) {   // a dangling link (folder or file) is an error: lstat sees it, stat does not
    try {
      lstatSync(p);
    } catch (e: any) {
      if (e?.code === "ENOENT" || e?.code === "ENOTDIR") return { path: join(repo, MCP_FILE), label: MCP_FILE };
      throw new ModelsError(`${p} cannot be read (${e?.code ?? e})`);
    }
    try {
      statSync(p);
    } catch (e: any) {
      throw new ModelsError(`${p} cannot be read (${e?.code ?? e}) – a dangling link?`);
    }
  }
  if (!statSync(file).isFile()) throw new ModelsError(`${file} is not a regular file`);
  return { path: file, label: `~/.nc/overlay/${MCP_FILE}` };
}

/** Read and check mcp/servers.yaml; returns the servers whose machines name this machine (machine()). Every entry is
 * checked, also those for the other machine. Throws ModelsError (exit 2) for anything that is not understood. */
export function loadServers(repo: string): McpServer[] {
  const here = machine();
  const { path, label } = mcpFile(repo);
  const bad = (msg: string): never => {
    throw new ModelsError(`${label}: ${msg}`);
  };
  const isMap = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (e: any) {
    return bad(`missing or not readable (${e?.code ?? e})`);
  }
  let doc: any;
  try {
    doc = Bun.YAML.parse(text);
  } catch (e: any) {
    return bad(`not valid YAML (${String(e?.message ?? e).split("\n")[0]})`);
  }
  if (!isMap(doc)) bad("the content is not a mapping (expected servers: {})");
  const unknownTop = Object.keys(doc).filter((k) => k !== "servers");
  if (unknownTop.length) bad(`unknown key ${q(unknownTop[0])} at the top level (allowed: servers)`);
  if (!isMap(doc.servers)) bad("servers missing or not a mapping (empty: servers: {})");

  const servers: McpServer[] = [];
  for (const [name, raw] of Object.entries(doc.servers as Record<string, any>)) {
    const at = `servers.${name}`;
    // Secrets first, in every text of the entry: the name, command, url, env names and values, header names.
    // Header values are checked below: there ${NC_MCP_…} is allowed.
    const texts: string[] = [name];
    const collect = (v: unknown) => {
      if (typeof v === "string") texts.push(v);
      else if (Array.isArray(v)) v.forEach(collect);
      else if (isMap(v)) for (const [k, x] of Object.entries(v)) (texts.push(k), collect(x));
    };
    collect(isMap(raw) && isMap(raw.headers) ? { ...raw, headers: Object.keys(raw.headers) } : raw);
    const secret = texts.find((t) => SECRET.test(t));
    if (secret !== undefined)
      bad(`${at}: ${q(secret)} – secrets in MCP only as \${NC_MCP_NAME} in a header value (\${…}, {env:…}, {file:…} anywhere else are refused)`);
    if (!ROLE_NAME.test(name)) bad(`${q(name)} is not a valid name (lowercase letters, digits, single hyphens)`);
    if (!isMap(raw)) bad(`${at} is not a mapping`);
    const e = raw as Record<string, any>;
    const allowed = e.type === "local" ? ["type", "command", "env", "machines"] : e.type === "remote" ? ["type", "url", "headers", "machines"] : null;
    if (!allowed) bad(`${at}.type is ${e.type === undefined ? "not set" : q(e.type)}, allowed: local, remote`);
    const unknown = Object.keys(e).filter((k) => !allowed!.includes(k));
    if (unknown.length) bad(`${at} has an unknown key ${q(unknown[0])} (with type: ${e.type} allowed: ${allowed!.join(", ")})`);

    if (!Array.isArray(e.machines) || !e.machines.length || e.machines.some((m: unknown) => typeof m !== "string" || !MACHINES.includes(m)))
      bad(`${at}.machines is ${q(e.machines)}, expected a non-empty subset of [${MACHINES.join(", ")}]`);
    if (new Set(e.machines).size !== e.machines.length) bad(`${at}.machines names a machine twice`);

    if (e.type === "local") {
      if (!Array.isArray(e.command) || !e.command.length || e.command.some((c: unknown) => typeof c !== "string" || c === ""))
        bad(`${at}.command is ${q(e.command)}, expected a non-empty list of texts`);
      let env: Record<string, string> | null = null;
      if (e.env !== undefined) {
        if (!isMap(e.env)) bad(`${at}.env is not a mapping`);
        for (const [k, v] of Object.entries(e.env as Record<string, unknown>)) {
          if (!ENV_NAME.test(k)) bad(`${at}.env: ${q(k)} is not the name of an environment variable`);
          if (k.startsWith("OPENROUTER_API_KEY")) bad(`${at}.env: ${k} – never put the OpenRouter key into env (a local server under nc opencode inherits it anyway)`);
          if (typeof v !== "string") bad(`${at}.env.${k} is ${q(v)}, expected a YAML text (in quotes)`);
        }
        env = e.env;
      }
      servers.push({ name, type: "local", command: e.command, env, machines: e.machines });
    } else {
      let ok = false;
      try {
        const u = new URL(e.url);
        ok = typeof e.url === "string" && (u.protocol === "https:" || (u.protocol === "http:" && LOCAL_HOSTS.includes(u.hostname)));
      } catch {}
      if (!ok) bad(`${at}.url is ${q(e.url)}, expected an https address (http only for ${LOCAL_HOSTS.join(", ")})`);
      let headers: Record<string, string> | null = null;
      if (e.headers !== undefined) {
        if (!isMap(e.headers) || !Object.keys(e.headers).length) bad(`${at}.headers is not a non-empty mapping`);
        for (const [k, v] of Object.entries(e.headers as Record<string, unknown>)) {
          if (!HEADER_NAME.test(k)) bad(`${at}.headers: ${q(k)} is not a header name`);
          // The value is never printed: it may hold a pasted token.
          if (typeof v !== "string" || /[\r\n]/.test(v)) bad(`${at}.headers.${k} is not a YAML text on one line (value not printed)`);
          if (SECRET.test((v as string).replace(SECRET_REF, "")))
            bad(`${at}.headers.${k}: only plain \${NC_MCP_NAME} references are allowed (A-Z, 0-9, _; no :-default; the value goes into secrets.env; value not printed)`);
        }
        headers = e.headers;
      }
      servers.push({ name, type: "remote", url: e.url, headers, machines: e.machines });
    }
  }
  return servers.filter((s) => s.machines.includes(here));
}

/** ~/.nc/mcp/claude.json for `claude --mcp-config=…` (nc claude). Remote is Streamable HTTP ("type": "http"). */
export function claudeMcpFile(servers: McpServer[]): string {
  const mcpServers: Record<string, unknown> = {};
  for (const s of servers)
    mcpServers[s.name] = s.type === "local"
      ? { command: s.command[0], args: s.command.slice(1), ...(s.env ? { env: s.env } : {}) }
      : { type: "http", url: s.url, ...(s.headers ? { headers: s.headers } : {}) };
  return JSON.stringify({ mcpServers }, null, 2) + "\n";
}

export const MCP_GENERATED = "// GENERATED by nc-harness – do not edit by hand";

/** <OpenCode config dir>/opencode.jsonc: OpenCode 2.2.7 loads it after opencode.json and merges mcp.servers by name
 * (checked with OpenCode 2.2.7). oauth: false – remote servers only without secrets, no OAuth flow. A remote server
 * with headers is left out: nc opencode does not export NC_MCP_*, the header would go out empty. */
export function opencodeMcpFile(servers: McpServer[]): string {
  const out: Record<string, unknown> = {};
  for (const s of servers.filter((x) => x.type === "local" || !x.headers))
    out[s.name] = s.type === "local"
      ? { type: "local", command: s.command, ...(s.env ? { environment: s.env } : {}) }
      : { type: "remote", url: s.url, oauth: false };
  return `${MCP_GENERATED}\n${JSON.stringify({ mcp: { servers: out } }, null, 2)}\n`;
}

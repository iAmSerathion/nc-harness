/**
 * mcp/servers.yaml – MCP servers, defined once. Read and checked here, written by nc generate on the
 * host only (never with --out: no MCP in task containers).
 *
 *   servers:
 *     <name>:                      # form of a role name
 *       type: local | remote
 *       command: [prog, arg, …]    # local only: a non-empty list of texts
 *       env: { NAME: "text" }      # local only, optional: values are YAML texts
 *       url: https://…             # remote only: Streamable HTTP, without secrets
 *       machines: [server, mac]    # required; only servers that name machine() are used
 *
 * Every deviation is exit 2. Secrets are not supported yet: `${`, `{env:` and `{file:` in any text of an entry are
 * refused (both runtimes would substitute them themselves, and under nc opencode the OpenRouter key is in the
 * environment), and so is an env name that starts with OPENROUTER_API_KEY. There is no starter that injects secrets
 * yet, so no headers either. Limit: a local server started by OpenCode under nc opencode inherits its environment,
 * OPENROUTER_API_KEY included; that stays until the starter comes.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { machine } from "./mode.ts";
import { ModelsError, ROLE_NAME } from "./models.ts";

export type McpServer =
  | { name: string; type: "local"; command: string[]; env: Record<string, string> | null; machines: string[] }
  | { name: string; type: "remote"; url: string; machines: string[] };

export const MCP_FILE = "mcp/servers.yaml";
const MACHINES = ["server", "mac"];
const SECRET = /\$\{|\{env:|\{file:/;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const q = (v: unknown) => JSON.stringify(v) ?? String(v);

/** Read and check mcp/servers.yaml; returns the servers whose machines name this machine (machine()). Every entry is
 * checked, also those for the other machine. Throws ModelsError (exit 2) for anything that is not understood. */
export function loadServers(repo: string): McpServer[] {
  const here = machine();
  const bad = (msg: string): never => {
    throw new ModelsError(`${MCP_FILE}: ${msg}`);
  };
  const isMap = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);
  let text: string;
  try {
    text = readFileSync(join(repo, MCP_FILE), "utf8");
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
    // Secrets first, in every text of the entry: the name, command, url, env names and values.
    const texts: string[] = [name];
    const collect = (v: unknown) => {
      if (typeof v === "string") texts.push(v);
      else if (Array.isArray(v)) v.forEach(collect);
      else if (isMap(v)) for (const [k, x] of Object.entries(v)) (texts.push(k), collect(x));
    };
    collect(raw);
    const secret = texts.find((t) => SECRET.test(t));
    if (secret !== undefined)
      bad(`${at}: ${q(secret)} – secrets in MCP not supported yet (\${…}, {env:…}, {file:…}; there is no starter yet that injects them)`);
    if (!ROLE_NAME.test(name)) bad(`${q(name)} is not a valid name (lowercase letters, digits, single hyphens)`);
    if (!isMap(raw)) bad(`${at} is not a mapping`);
    const e = raw as Record<string, any>;
    const allowed = e.type === "local" ? ["type", "command", "env", "machines"] : e.type === "remote" ? ["type", "url", "machines"] : null;
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
        ok = typeof e.url === "string" && new URL(e.url).protocol === "https:";
      } catch {}
      if (!ok) bad(`${at}.url is ${q(e.url)}, expected an https address`);
      servers.push({ name, type: "remote", url: e.url, machines: e.machines });
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
      : { type: "http", url: s.url };
  return JSON.stringify({ mcpServers }, null, 2) + "\n";
}

export const MCP_GENERATED = "// GENERATED by nc-harness – do not edit by hand";

/** <OpenCode config dir>/opencode.jsonc: OpenCode 2.2.7 loads it after opencode.json and merges mcp.servers by name
 * (checked with OpenCode 2.2.7). oauth: false – remote servers only without secrets, no OAuth flow. */
export function opencodeMcpFile(servers: McpServer[]): string {
  const out: Record<string, unknown> = {};
  for (const s of servers)
    out[s.name] = s.type === "local"
      ? { type: "local", command: s.command, ...(s.env ? { environment: s.env } : {}) }
      : { type: "remote", url: s.url, oauth: false };
  return `${MCP_GENERATED}\n${JSON.stringify({ mcp: { servers: out } }, null, 2)}\n`;
}

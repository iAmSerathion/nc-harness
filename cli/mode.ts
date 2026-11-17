import { join } from "node:path";
import { ModelsError } from "./models.ts";

/** The two modes: direct (host) and isolated (task container). nc-work sets NC_HARNESS_VERSION in every task container. */
export type Mode = "direct" | "isolated";

export function mode(): Mode {
  return process.env.NC_HARNESS_VERSION ? "isolated" : "direct";
}

/** The two machine types. Isolation (nc-work, nc delegate) exists only on "server". */
export type Machine = "server" | "mac";

/**
 * NC_MACHINE (server or mac) if set and not empty, else macOS is "mac" and everything else "server". Set it to
 * override the guess, for example NC_MACHINE=mac on a Linux laptop without isolation. Any other value throws ModelsError:
 * exit 2 in nc generate, a fail line in nc doctor.
 * shortcut: Linux is always server; a third machine type needs a case of its own here.
 */
export function machine(): Machine {
  const v = process.env.NC_MACHINE;
  if (v) {
    if (v === "server" || v === "mac") return v;
    throw new ModelsError(`NC_MACHINE is ${JSON.stringify(v)}, allowed: server, mac`);
  }
  return process.platform === "darwin" ? "mac" : "server";
}

/** The harness' own folder on the host: NC_HOME, else ~/.nc (same rule as install.sh). */
export const ncHome = (home: string) => process.env.NC_HOME || join(home, ".nc");

/** Harness commit, 7 characters. Isolated: the snapshot nc-work mounted. Direct: HEAD of the checkout (+dirty). */
export function commit(repo: string): string {
  const snapshot = process.env.NC_HARNESS_VERSION;
  if (snapshot) return snapshot.slice(0, 7);
  const git = (...args: string[]) =>
    Bun.spawnSync(["git", "-C", repo, ...args], { stdout: "pipe", stderr: "pipe", timeout: 10_000 });
  const head = git("rev-parse", "--short=7", "HEAD");
  if (!head.success) return "unknown";
  const dirty = git("status", "--porcelain").stdout.toString().trim() !== "";
  return head.stdout.toString().trim() + (dirty ? "+dirty" : "");
}

/**
 * The one global config dir OpenCode 2.2.7 reads: OPENCODE_CONFIG_DIR, else XDG_CONFIG_HOME/opencode, else
 * ~/.config/opencode. A variable that is set replaces ~/.config/opencode, it does not add to it. Same rule as
 * cli/opencode.sh; used by nc doctor and nc generate.
 */
export function opencodeConfigDir(home: string): string {
  return process.env.OPENCODE_CONFIG_DIR || join(process.env.XDG_CONFIG_HOME || join(home, ".config"), "opencode");
}

/**
 * Requests from a task container to the host: reading a request file the container wrote, and the
 * format of the broker's requests and answers (version 1). Used by nc memory (outbox, mailbox) and nc delegate (mailbox).
 * A memory request ({"v":1,"type":"memory","text":"…"}) is checked by nc memory apply --broker (cli/memory.ts), not here:
 * checkRequest stays with delegate and cleanup and refuses it.
 *
 * A request file is never trusted: opened without following a link and without blocking on a FIFO, only a regular
 * file, at most `limit` bytes (checked again after reading), strict UTF-8, exactly one JSON object.
 */
import { closeSync, constants, fstatSync, openSync, readSync } from "node:fs";

/** A request that is refused; the message is meant for the user. */
export class RequestError extends Error {}

/** The bytes of one request file, at most `limit`. */
export function readBounded(path: string, limit: number): Buffer {
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (e: any) {
    throw new RequestError(e?.code === "ELOOP" ? "is a link" : `not readable (${e?.code ?? e})`);
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile()) throw new RequestError("not a regular file");
    if (st.size > limit) throw new RequestError(`larger than ${limit} bytes`);
    const buf = Buffer.alloc(limit + 1);
    let used = 0;
    for (;;) {
      const n = readSync(fd, buf, used, buf.length - used, null);
      if (n <= 0) break;
      used += n;
      if (used > limit) throw new RequestError(`larger than ${limit} bytes`);
    }
    return buf.subarray(0, used);
  } finally {
    closeSync(fd);
  }
}

/** Strict UTF-8, one JSON object (no array, no null). */
export function parseObject(raw: Uint8Array): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
  } catch {
    throw new RequestError("not valid JSON (UTF-8)");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new RequestError("not a JSON object");
  return value as Record<string, unknown>;
}

export function rejectUnknown(obj: Record<string, unknown>, keys: Set<string>) {
  for (const k of Object.keys(obj)) if (!keys.has(k)) throw new RequestError(`unknown field ${JSON.stringify(k).slice(0, 40)}`);
}

// --- the broker's format (nc delegate from a task container) ----------------------------------------------------

/** Task IDs of nc delegate: d<MMDD>-<hhmm>-<4 hex>; also the nc-work task and the herdr terminal of a worker. */
export const ID = /^d[0-9]{4}-[0-9]{4}-[0-9a-f]{4}$/;
export const MODEL = /^[A-Za-z0-9._:\/#-]{1,200}$/;
/** File name of a request in the mailbox; its answer folder in the inbox is the name without .json. */
export const REQUEST_NAME = /^[a-z0-9][a-z0-9-]{0,63}\.json$/;
export const REQUEST_BYTES = 64 * 1024;
export const TASK_BYTES = 20 * 1024;
export const REASON_CHARS = 400;
const DELEGATE_KEYS = new Set(["v", "type", "role", "task", "model", "timeout"]);
const CLEANUP_KEYS = new Set(["v", "type", "task_id"]);

export type DelegateRequest = { type: "delegate"; role: string; task: string; model: string | null; timeout: number };
export type CleanupRequest = { type: "cleanup"; task_id: string };

/**
 * One request of the broker's format, checked whole:
 *   {"v": 1, "type": "delegate", "role": "tester", "task": "…", "model": null, "timeout": 20}
 *   {"v": 1, "type": "cleanup", "task_id": "d1115-1432-ab12"}
 * Fields like project, path, repo, profile or requester are unknown: the host takes them from the folder.
 */
export function checkRequest(obj: Record<string, unknown>): DelegateRequest | CleanupRequest {
  if (obj.v !== 1) throw new RequestError(`version ${String(JSON.stringify(obj.v)).slice(0, 40)} unknown, expected 1`);
  if (obj.type === "cleanup") {
    rejectUnknown(obj, CLEANUP_KEYS);
    if (typeof obj.task_id !== "string" || !ID.test(obj.task_id)) throw new RequestError("task_id missing or not a valid ID");
    return { type: "cleanup", task_id: obj.task_id };
  }
  if (obj.type !== "delegate") throw new RequestError(`type ${String(JSON.stringify(obj.type)).slice(0, 40)} unknown (delegate or cleanup)`);
  rejectUnknown(obj, DELEGATE_KEYS);
  if (typeof obj.role !== "string" || !/^[a-z][a-z0-9-]{0,39}$/.test(obj.role)) throw new RequestError("role missing or not a role name");
  if (typeof obj.task !== "string" || !obj.task.trim()) throw new RequestError("task missing or empty");
  const bytes = Buffer.byteLength(obj.task, "utf8");
  if (bytes > TASK_BYTES) throw new RequestError(`task has ${bytes} bytes, at most ${TASK_BYTES}`);
  const model = obj.model ?? null;
  if (model !== null && (typeof model !== "string" || !MODEL.test(model))) throw new RequestError("model is not a valid model ID");
  const timeout = obj.timeout ?? 20;
  if (typeof timeout !== "number" || !Number.isInteger(timeout) || timeout < 1 || timeout > 20) throw new RequestError("timeout: whole minutes from 1 to 20");
  return { type: "delegate", role: obj.role, task: obj.task, model: model as string | null, timeout };
}

/** States of an answer in the inbox (inbox/<name without .json>/response.json, written by the host). stored: a memory request
 * was applied (result {"outcome", "pushed"}). */
export const STATES = ["refused", "started", "done", "cleaned", "stored", "error"] as const;
export type Response = {
  v: 1; request: string; state: (typeof STATES)[number]; reason: string | null; task_id: string | null;
  timeout_min: number | null; started: string | null; result: Record<string, unknown> | null;
  /** cleaned only: true when neither run folder nor worker task was left, so the host had nothing to clean up. */
  gone?: boolean;
};

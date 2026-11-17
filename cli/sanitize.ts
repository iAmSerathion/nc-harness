/**
 * Cleaning of text that comes from a container or a worker (nc memory requests, nc delegate results). Whatever
 * reaches a terminal, a file the host reads or a model context must not hide anything: control characters and
 * characters that are invisible in a terminal are either written out (`visible`) or removed (`cleanText`).
 */

/**
 * Invisible in a terminal, so the host could not see what it applies: soft hyphen, combining grapheme joiner,
 * Arabic letter mark, Mongolian vowel separator, zero-width, bidi, word joiner, Hangul filler, variation selectors
 * (U+FE0F stays allowed for emoji), BOM, tag characters.
 */
const INVISIBLE_CHARS = "\\u00ad\\u034f\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u2069\\u3164\\ufe00-\\ufe0e\\ufeff";
const INVISIBLE_SUPP = "[\\u{e0000}-\\u{e007f}\\u{e0100}-\\u{e01ef}]";
export const INVISIBLE = new RegExp(`[${INVISIBLE_CHARS}]|${INVISIBLE_SUPP}`, "u");
const UNSAFE = new RegExp(`[\\u0000-\\u001f\\u007f-\\u009f${INVISIBLE_CHARS}]|${INVISIBLE_SUPP}`, "gu");
/** Like UNSAFE, but newline and tab stay. */
const UNSAFE_TEXT = new RegExp(`[\\u0000-\\u0008\\u000b-\\u001f\\u007f-\\u009f${INVISIBLE_CHARS}]|${INVISIBLE_SUPP}`, "gu");

/** Control and invisible characters written out as \u{…}: for anything from a container that reaches a terminal or a .reason file. */
export const visible = (s: string) => s.replace(UNSAFE, (c) => `\\u{${c.codePointAt(0)!.toString(16)}}`);

/** Control characters (except newline and tab) and invisible characters removed. CR goes too, so CRLF becomes LF. */
export const cleanText = (s: string) => s.replace(UNSAFE_TEXT, "");

export const RESULT_LIMIT = 64 * 1024;
const TRUNCATED_NOTE = "\n\n[nc delegate: cut – RESULT.md was longer than 64 KiB]\n";

/** The longest prefix of `s` (whole code points) whose UTF-8 encoding has at most `bytes` bytes. */
function cutUtf8(s: string, bytes: number): string {
  let used = 0;
  let end = 0;
  for (const ch of s) {
    const n = Buffer.byteLength(ch, "utf8");
    if (used + n > bytes) break;
    used += n;
    end += ch.length;
  }
  return s.slice(0, end);
}

/**
 * RESULT.md of a worker as the host keeps it. Bytes are decoded as UTF-8 without failing: an invalid sequence
 * becomes U+FFFD, a visible mark that something was there, so no raw byte survives. `cutUpstream`: the bytes were
 * already cut (nc-work export keeps the first 64 KiB); an incomplete last character is then dropped instead of
 * showing up as U+FFFD. Then cleanText, and at most RESULT_LIMIT bytes of UTF-8, cut at a character boundary,
 * with a note at the end when anything was cut.
 */
export function cleanResult(raw: Uint8Array, cutUpstream = false): string {
  const decoded = new TextDecoder("utf-8", { fatal: false }).decode(raw, { stream: cutUpstream });
  const text = cleanText(decoded);
  if (!cutUpstream && Buffer.byteLength(text, "utf8") <= RESULT_LIMIT) return text;
  return cutUtf8(text, RESULT_LIMIT - Buffer.byteLength(TRUNCATED_NOTE, "utf8")) + TRUNCATED_NOTE;
}

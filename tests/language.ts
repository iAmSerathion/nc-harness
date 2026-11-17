/**
 * Language guard (English only): fails on German in any file of the repo that
 * `git ls-files --cached --others --exclude-standard` lists, apart from ALLOWED.
 * A port of nc-infra's LanguageGuardTests (work-environments/tests/test_policy.py), with the same word lists.
 * Run by tests/language.sh. Exit 0 clean, 1 German found, a file that is not valid UTF-8 or a stale allow-list entry,
 * 2 git failed or listed nothing. A file with a NUL byte is binary and skipped; a file that cannot be read is skipped
 * and named on stderr.
 *
 * The guard's own words carry a 0 that plain() strips at runtime, and German letters are \u escapes, so this file
 * does not match itself and is scanned like every other file.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const plain = (text: string) => text.replaceAll("0", "");

const CHARS = "[\u00e4\u00f6\u00fc\u00c4\u00d6\u00dc\u00df\u201e\u201c]";
const PREFIXES = plain("auf0tr ver0mittler schl\u00fc0ssel schlu0essel ged\u00e40chtnis an0frage no0tiz post0fach ein0gang ab0gelehnt " +
  "ab0gebrochen ge0startet ge0speichert feh0ler feh0lt un0gueltig gue0ltig zu0rueck").split(" ");
const WORDS = plain("u0nd ni0cht o0der wi0rd i0st er0st no0ch sch0on d0er d0as d0em z0u b0ei a0uf n0ur we0nn ke0in ke0ine e0in ei0ne " +
  "ei0nen si0ch au0ch w0ir fer0tig ne0in schr0eibe oh0ne fal0scher or0dner da0tei la0uf te0il").split(" ");
/** Harness additions, whole words, case-insensitive; none of them is an English word. */
const HARNESS_WORDS = plain("dir0ekt iso0liert unbe0kannt aufge0frischt er0setzt projekt0pfad bei0spiel pa0ket ent0fernt").split(" ");
const CASED = [plain("m0it")];  // lowercase only: "Mit" is not counted
const SUBSTRINGS = plain("kun0den ver0trieb").split(" ");  // no word boundary
// Never add die, den, an, in, so, was, will, bin, man, hat, also or war: they are English words too.

/** JS \b is ASCII-only. A word character is what Python's \b counts: any letter (umlauts included), digit or underscore. */
const W = "[\\p{L}\\p{N}_]";
const PATTERNS = [
  new RegExp(CHARS, "u"),
  new RegExp(`(?<!${W})(?:${PREFIXES.join("|")})`, "iu"),
  new RegExp(`(?<!${W})(?:${[...WORDS, ...HARNESS_WORDS].join("|")})(?!${W})`, "iu"),
  new RegExp(`(?<!${W})(?:${CASED.join("|")})(?!${W})`, "u"),
  new RegExp(SUBSTRINGS.join("|"), "iu"),
];
const MARKER = "# lang-guard: " + "patterns";  // fallback: one marked line in the whole tree is skipped, no more

/** (file, literal): the literal is cut out of its lines before matching. Every entry must still occur in its file. */
const ALLOWED: [string, string][] = [];

/** The first German match in one line, or null. The line is NFC-normalized first, so a decomposed umlaut (a + U+0308)
 * counts. Escape sequences \n, \t and \r count as a space. */
export function hit(line: string): string | null {
  const text = line.normalize("NFC").replaceAll("\\n", " ").replaceAll("\\t", " ").replaceAll("\\r", " ");
  for (const pattern of PATTERNS) {
    const found = text.match(pattern);
    if (found) return found[0];
  }
  return null;
}

/** What the scan does with a file, from its raw bytes: "skip" when they contain a NUL (binary, checked before
 * decoding), "fail" when they are not valid UTF-8, "text" otherwise. */
export function classify(raw: Uint8Array): "skip" | "fail" | "text" {
  if (raw.includes(0)) return "skip";
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(raw);
    return "text";
  } catch {
    return "fail";
  }
}

function selfTest(): string[] {
  const errors: string[] = [];
  const german = [plain("Au0ftrag"), "gr\u00f6\u00dfer", plain("x ni0cht y"), plain('"\\nni0cht"'), plain("m0it"), plain("KUN0DENLISTE"),
    plain("x-ver0trieb"), plain("\u201eZitat\u201c"), plain("Ged\u00e40chtnis"), plain("fe0hlt"),
    plain("mode: dir0ekt"), plain("ISO0LIERT"), plain("unbe0kannt"), plain("aufge0frischt"), plain("er0setzt"), plain("PROJEKT0PFAD"),
    plain("Bei0spiel"), plain("Pa0ket"), plain("ent0fernt"), plain("\u00fcber u0nd"), plain("a_b u0nd"),
    "Ma\u0308rz", plain("Auf0tragsliste"), plain('"\\tni0cht"'), plain('"\\rni0cht"'), "\u201c"];
  for (const text of german) if (hit(text) === null) errors.push(`self-test: not caught: ${JSON.stringify(text)}`);
  const english = ["die den an in so was will bin man hat also war", "Mit", "the broker stopped during hand-over", "refused (too large)",
    "en dash \u2013 and ellipsis \u2026 are fine", "start, inbox, notice, auction, disturb", "direct isolated unknown replaced refreshed",
    "example package removed PROJECT_PATH", plain("und0efined un0done x_i0st_y mitigate"), plain("xauf0tragsliste")];
  for (const text of english) if (hit(text) !== null) errors.push(`self-test: wrongly caught ${JSON.stringify(hit(text))} in ${JSON.stringify(text)}`);
  const bytes: [number[], string][] = [[[0x61, 0x00, 0xff], "skip"], [[0x63, 0x61, 0x66, 0xe9, 0x0a], "fail"], [[...Buffer.from("plain ASCII\n")], "text"]];
  for (const [raw, want] of bytes) {
    const got = classify(new Uint8Array(raw));
    if (got !== want) errors.push(`self-test: classify(${JSON.stringify(raw)}) is ${got}, want ${want}`);
  }
  return errors;
}

function main(): number {
  const repo = resolve(dirname(import.meta.path), "..");
  const errors = selfTest();
  const listed = Bun.spawnSync(["git", "-C", repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard"], { stdout: "pipe", stderr: "pipe" });
  const files = [...new Set(listed.stdout.toString().split("\0").filter(Boolean))].sort();
  if (!listed.success || !files.length) {  // never a skip
    process.stderr.write(`language guard: git ls-files failed or listed nothing: ${listed.stderr.toString().trim()}\n`);
    return 2;
  }
  const allowed = new Map<string, string[]>();
  for (const [f, literal] of ALLOWED) allowed.set(f, [...(allowed.get(f) ?? []), literal]);
  const hits: string[] = [];
  const binary: string[] = [];
  const invalid: string[] = [];
  const unreadable: string[] = [];
  const used = new Set<string>();
  const marked: string[] = [];
  let scanned = 0;
  for (const f of files) {
    const path = join(repo, f);
    if (!existsSync(path)) continue;  // deleted in the work tree, not yet staged: nothing left to read
    let bytes: Uint8Array;
    try {
      bytes = readFileSync(path);
    } catch {  // a folder (a gitlink), no permission: named on stderr, not a failure
      unreadable.push(f);
      continue;
    }
    const kind = classify(bytes);
    if (kind === "skip") {
      binary.push(f);
      continue;
    }
    if (kind === "fail") {
      invalid.push(f);
      continue;
    }
    scanned++;
    new TextDecoder("utf-8").decode(bytes).split("\n").forEach((raw, i) => {
      if (raw.includes(MARKER)) return void marked.push(`${f}:${i + 1}`);
      let line = raw.normalize("NFC");
      for (const literal of allowed.get(f) ?? [])
        if (line.includes(literal)) {
          used.add(JSON.stringify([f, literal]));
          line = line.replaceAll(literal, " ");
        }
      const word = hit(line);
      if (word !== null) hits.push(`${f}:${i + 1}: ${JSON.stringify(word)}`);
    });
  }
  if (binary.length) process.stderr.write(`language guard: binary (NUL byte), skipped: ${binary.join(", ")}\n`);
  if (unreadable.length) process.stderr.write(`language guard: not readable, skipped: ${unreadable.join(", ")}\n`);
  if (invalid.length) errors.push(`not valid UTF-8:\n${invalid.join("\n")}`);
  if (hits.length) errors.push(`German text:\n${hits.join("\n")}`);
  const stale = ALLOWED.filter((e) => !used.has(JSON.stringify(e)));
  if (stale.length) errors.push(`allow-list entries that match nothing any more:\n${stale.map((e) => JSON.stringify(e)).join("\n")}`);
  if (marked.length > 1) errors.push(`more than one line marked ${JSON.stringify(MARKER)}: ${marked.join(", ")}`);
  if (errors.length) {
    process.stderr.write(`language guard: FAIL\n${errors.join("\n")}\n`);
    return 1;
  }
  console.log(`language guard: ok (${scanned} files, ${ALLOWED.length} allowed literals)`);
  return 0;
}

process.exit(main());

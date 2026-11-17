"""cli/delegate-events.py [TARGET] – filter behind `opencode run --format json` in cli/delegate-run.sh.

Reads OpenCode's JSON events from stdin until EOF. With TARGET (the run's events.jsonl on the host) it stores every
line raw: the file is created new (O_EXCL, O_NOFOLLOW, mode 600), only whole lines, at most 16 MiB in all; after
that nothing more is stored. On stdout (the herdr pane of the worker) it shows only the answer texts, one short line
per tool call and shortened error events, cleaned like cleanText in cli/sanitize.ts. Lines that are not JSON are
never shown raw, only as "(line without JSON, N bytes)".

It never ends before EOF and always exits 0: every line is handled on its own, and a write error (a closed pane
gives EIO, a full disk ENOSPC) only stops writing there. Otherwise `docker exec` would get SIGPIPE and the worker
would end in the middle of its work. SIGHUP and SIGINT are ignored for the same reason: the run's end closes the
pipe, and then this filter ends too.
Standard library only; run as `python3 -I -B`.
"""
import json
import os
import re
import signal
import sys

STORE_MAX = 16 * 1024 * 1024   # bytes stored in TARGET
LINE_MAX = 1024 * 1024         # bytes of one line that are read into memory and evaluated
CHUNK = 64 * 1024
TEXT_MAX = 64 * 1024           # characters of one answer text shown
SHORT = 200                    # characters of a tool or error line

# Same classes as cli/sanitize.ts (UNSAFE_TEXT): C0 except \n and \t, DEL, C1, invisible and bidi characters, tags.
INVISIBLE = ("­͏؜᠎​-‏‪-‮⁠-⁤⁦-⁩ㅤ︀-︎﻿"
             "\U000e0000-\U000e007f\U000e0100-\U000e01ef")
UNSAFE_TEXT = re.compile("[\u0000-\u0008\u000b-\u001f\u007f-\u009f" + INVISIBLE + "]")


def clean(text):
    return UNSAFE_TEXT.sub("", text)


def short(text, limit=SHORT):
    """One line: cleaned, whitespace runs (newlines too) as one space, cut with an ellipsis."""
    text = " ".join(clean(str(text)).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


class Out:
    """fd 1 directly (no buffer that could fail again at exit); after the first error nothing more is written there."""

    def __init__(self):
        self.ok = True

    def say(self, text):
        if not self.ok:
            return
        data = text.encode("utf-8", errors="replace")
        try:
            while data:
                data = data[os.write(1, data):]
        except InterruptedError:
            self.say(data.decode("utf-8", errors="replace"))
        except OSError:
            self.ok = False


class Store:
    """TARGET: whole raw lines up to STORE_MAX. A line longer than LINE_MAX is written in pieces; if it does not fit,
    the file is cut back to where the line began, so it only ever holds whole lines."""

    def __init__(self, path):
        self.fd = None
        self.size = 0
        self.line_start = 0
        if path is None:
            return
        try:
            self.fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        except OSError as e:
            warn(f"{path} not created ({e.strerror}) – events are only shown")

    def write(self, data, line_ends):
        if self.fd is None:
            return
        if self.size + len(data) > STORE_MAX:
            self.cut()
            return
        try:
            view = memoryview(data)
            while view:  # a short write (full disk) is retried; the error after it cuts back to the line start
                n = os.write(self.fd, view)
                self.size += n
                view = view[n:]
            if line_ends:
                self.line_start = self.size
        except OSError:
            self.cut()

    def cut(self):
        try:
            os.ftruncate(self.fd, self.line_start)
        except OSError:
            pass
        self.stop()

    def stop(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        self.fd = None


def warn(text):
    try:
        sys.stderr.write(f"delegate-events: {text}\n")
        sys.stderr.flush()
    except (OSError, ValueError):
        pass


def show(line, out):
    """One complete line of at most LINE_MAX bytes."""
    try:
        event = json.loads(line.decode("utf-8", errors="replace"))
    except (ValueError, RecursionError):
        if line.strip():
            out.say(f"(line without JSON, {len(line)} bytes)\n")
        return
    if not isinstance(event, dict):
        out.say(f"(line without JSON, {len(line)} bytes)\n")
        return
    kind = event.get("type")
    part = event.get("part") if isinstance(event.get("part"), dict) else {}
    if kind == "text" and isinstance(part.get("text"), str):
        text = clean(part["text"])
        if len(text) > TEXT_MAX:
            text = text[:TEXT_MAX] + " …"
        out.say(text.rstrip("\n") + "\n")
    elif kind == "tool_use":
        state = part.get("state") if isinstance(part.get("state"), dict) else {}
        inp = state.get("input") if isinstance(state.get("input"), dict) else {}
        what = inp.get("command") or inp.get("path") or inp.get("filePath") or inp.get("pattern") or inp.get("url") or state.get("title") or ""
        status = state.get("status") if isinstance(state.get("status"), str) else ""
        out.say(f"→ {short(part.get('tool') or '?', 40)}{' (' + short(status, 20) + ')' if status and status != 'completed' else ''}: {short(what, SHORT)}\n")
    elif kind == "error":
        err = event.get("error") if isinstance(event.get("error"), dict) else {}
        data = err.get("data") if isinstance(err.get("data"), dict) else {}
        kind = err.get("type") or err.get("name") or "?"
        message = err.get("message") or data.get("message") or ""
        out.say(f"error: {short(kind, 60)}: {short(message, 300)}\n")


def main():
    for sig in (signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, signal.SIG_IGN)
    store = Store(sys.argv[1] if len(sys.argv) > 1 else None)
    out = Out()
    buf = b""          # the current line, as long as it is at most LINE_MAX
    long_line = 0      # bytes of the current line once it is longer than LINE_MAX (then not evaluated)
    while True:
        try:
            chunk = os.read(0, CHUNK)
        except InterruptedError:
            continue
        except OSError:
            break
        if not chunk:
            break
        pos = 0
        while pos < len(chunk):  # an offset, not chunk[nl + 1:]: no copy of the rest for every line
            nl = chunk.find(b"\n", pos)
            end = len(chunk) if nl < 0 else nl + 1
            piece, pos = chunk[pos:end], end
            done = nl >= 0
            try:
                if long_line:
                    store.write(piece, done)
                    long_line += len(piece)
                elif len(buf) + len(piece) > LINE_MAX:
                    store.write(buf + piece, done)
                    long_line = len(buf) + len(piece)
                    buf = b""
                else:
                    buf += piece
                    if done:
                        store.write(buf, True)
                if done:
                    if long_line:
                        out.say(f"(line of {long_line} bytes, not read)\n")
                    else:
                        show(buf.rstrip(b"\n"), out)
                    buf, long_line = b"", 0
            except Exception as e:  # never end before EOF
                warn(f"line skipped ({type(e).__name__})")
                buf, long_line = b"", 0
    try:
        if buf or long_line:  # the last line without a newline
            store.write(buf, True)
            if long_line:
                out.say(f"(line of {long_line + len(buf)} bytes, not read)\n")
            else:
                show(buf, out)
    except Exception as e:
        warn(f"last line skipped ({type(e).__name__})")
    if store.fd is not None:
        store.stop()
    return 0


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        warn(f"unexpected error ({type(e).__name__})")
    sys.exit(0)

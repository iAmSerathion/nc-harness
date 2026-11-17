#!/usr/bin/env bash
# cli/delegate-run.sh ID – the worker of `nc delegate`, run by `hc run --bg … -- bash -lc '<harness>/cli/delegate-run.sh ID'`
# in a herdr terminal on the host, always from the harness checkout (never from a task snapshot).
#
# Reads ~/.nc/delegate/ID/request.json (role, model override, time limit) and prompt.md (contract + task), runs
#   timeout --foreground -k 60s -s TERM <min>m nc-work opencode ID -- run --format json --agent <role> [--model M] "<prompt>" </dev/null \
#     | python3 -I -B cli/delegate-events.py ~/.nc/delegate/ID/events.jsonl
# (written as a process substitution: the filter stores the raw events for cost_usd and shows only readable text in
# the pane; it reads to EOF and exits 0, and the exit code is the one of timeout; the filter gets at most 10 seconds
# after the run) and afterwards always writes status.json {"exit": N, "ended": "<ISO>"} (atomic via rename), also when it is
# interrupted (trap). --foreground: in a terminal nc-work could otherwise hang in a background process group;
# </dev/null: OpenCode runs without a terminal on stdin. 124 (TERM after the limit) or 137 (KILL 60 s later)
# mean timeout to nc delegate. No key is read here; nc-work opencode does that.
set -uo pipefail

id="${1:-}"
[[ "$id" =~ ^d[0-9]{4}-[0-9]{4}-[0-9a-f]{4}$ ]] || { echo "delegate-run: invalid ID" >&2; exit 2; }
dir="$HOME/.nc/delegate/$id"
[ -d "$dir" ] && [ ! -L "$dir" ] || { echo "delegate-run: run folder $dir missing" >&2; exit 2; }

rc=125
ran=0  # 1 once wait has returned: rc is then the real exit code and a late signal must not replace it
written=0
filter=""
# The filter ends at EOF. A process that inherited its pipe and outlived nc-work (after the KILL of timeout) would keep
# it open: so wait for it at most 10 seconds after the run, then end it.
stop_filter() {
  [ -n "$filter" ] || return 0
  for _ in $(seq 50); do kill -0 "$filter" 2>/dev/null || break; sleep 0.2; done
  kill "$filter" 2>/dev/null || true
  filter=""
}
runner=""
# status.json first: a closed pane hangs up and then kills (hc kill: SIGHUP, later SIGKILL), so nothing may come before it.
write_status() {
  if [ "$written" = 0 ]; then
    written=1
    printf '{"exit": %d, "ended": "%s"}\n' "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/.status.tmp" \
      && mv -f "$dir/.status.tmp" "$dir/status.json"
    trap '' HUP INT TERM  # a second signal must not cut stop_filter short and leave the filter running
  fi
  exec 3>&- 2>/dev/null  # our end of the filter's pipe; then it sees EOF once the run's processes are gone
  stop_filter
}
# timeout runs in the background and is waited for with `wait`, which a signal interrupts at once (a foreground command
# would delay the trap until it ends). The signal goes on to timeout, which hands it to nc-work for its own clean-up.
# After wait has returned (e.g. during stop_filter) rc stays the real code: a done or timed-out run is no failure.
on_signal() { [ "$ran" = 1 ] || rc=$1; [ -z "$runner" ] || kill -s "$2" "$runner" 2>/dev/null; exit "$1"; }
trap write_status EXIT
trap 'on_signal 129 HUP' HUP
trap 'on_signal 130 INT' INT
trap 'on_signal 143 TERM' TERM

# request.json was written by nc delegate; checked again here, values go into argv only.
fields="$(python3 -I -B -c '
import json, re, sys
r = json.load(open(sys.argv[1]))
role, model, minutes = r["role"], r.get("model_override") or "", r["timeout_min"]
assert role in ("implementer", "tester", "researcher")  # researcher: only older runs; nc delegate starts none
assert model == "" or re.fullmatch(r"[A-Za-z0-9._:/#-]{1,200}", model)
assert isinstance(minutes, int) and 1 <= minutes <= 20
print(role); print(minutes); print(model)
' "$dir/request.json")" || { echo "delegate-run: request.json not readable" >&2; rc=2; exit 2; }
{ read -r role; read -r minutes; read -r model; } <<<"$fields"
[ -f "$dir/prompt.md" ] || { echo "delegate-run: prompt.md missing" >&2; rc=2; exit 2; }

events="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/delegate-events.py"
[ -f "$events" ] || { echo "delegate-run: $events missing" >&2; rc=2; exit 2; }

echo "nc delegate: worker $id ($role, at most $minutes minutes)"
args=(run --format json --agent "$role")
[ -z "$model" ] || args+=(--model "$model")
# On fd 3, not `cmd > >(…)`: only `exec` gives the filter's pid in $! (bash 5.2).
exec 3> >(exec python3 -I -B "$events" "$dir/events.jsonl")
filter=$!
timeout --foreground -k 60s -s TERM "${minutes}m" nc-work opencode "$id" -- "${args[@]}" "$(cat "$dir/prompt.md")" </dev/null >&3 3>&- &
runner=$!
wait "$runner"
rc=$?
ran=1
runner=
exec 3>&-
stop_filter
echo "nc delegate: worker $id ended (exit $rc). Result: nc delegate --result $id"
exit "$rc"

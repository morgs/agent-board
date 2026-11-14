#!/bin/bash
# Verifies the Codex CLI side of the hooks: `agentboard hook-* --codex`.
#
# Codex sends nearly the same payloads as Claude Code, but answers differently:
#   - PreToolUse takes only "deny" (allow and ask are errors), or exit 2 + stderr
#   - Stop has no additionalContext; {"decision":"block","reason":...} feeds the model
#   - SessionEnd gets one second
#   - files are edited with apply_patch, whose tool_input.command is a patch text
#
# Self-contained like policy-matrix.sh: a throwaway AGENT_BOARD_DIR and throwaway
# repos. Every hook of the "Codex session" runs under one long-lived process whose
# name is `codex`, so the board identifies it exactly as it does a real one.
#
#   ~/agent-board/test/codex-hooks.sh
set -uo pipefail

AB=${AB:-$HOME/agent-board/bin/agentboard}
export AB AGENT_BOARD_DIR AGENT_BOARD_CC_SESSIONS
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentboard-codex.XXXXXX")" && pwd -P)
AGENT_BOARD_DIR="$T/board"
AGENT_BOARD_CC_SESSIONS="$T/cc"
mkdir -p "$AGENT_BOARD_DIR" "$AGENT_BOARD_CC_SESSIONS" "$T/bin"
cat > "$AGENT_BOARD_DIR/workspace.local" <<'WS'
[shared-main]
infra
[no-branch]
infra
WS
FAKES=()
cleanup() {
  for p in ${FAKES+"${FAKES[@]}"}; do kill "$p" 2>/dev/null; done
  [ -n "${KEEP:-}" ] || rm -rf "$T"   # KEEP=1 leaves it for a look
}
trap cleanup EXIT

D="$T/infra"
mkdir -p "$D"
git -C "$D" init -q -b main
git -C "$D" config user.email t@t; git -C "$D" config user.name t
{ printf '$ANSIBLE_VAULT;1.1;AES256\n'; printf '3132333435\n'; } > "$D/vault.yml"
printf -- '- hosts: all\n' > "$D/site.yml"
printf 'a\n' > "$D/shared.yml"
printf 'b\n' > "$D/mine.yml"
git -C "$D" add vault.yml site.yml shared.yml mine.yml; git -C "$D" commit -qm init

# A live peer in the same repo, sitting on shared.yml.
sleep 3000 </dev/null >/dev/null 2>&1 &
PEER=$!; disown "$PEER" 2>/dev/null; FAKES+=("$PEER")
"$AB" claim --pid "$PEER" --agent claude --name peer --cwd "$D" --scope 'peer work' >/dev/null
printf 'edited by the peer\n' >> "$D/shared.yml"
printf '%s\t%s\n' "$D" shared.yml >> "$AGENT_BOARD_DIR/paths/$PEER"

# The Codex session: one process named "codex" that runs the cases in a child bash,
# the way Codex spawns its hooks. Forks of the child are "bash", so every hook walks
# up to the same codex pid ($PPID in the child).
ln -s "$(command -v bash)" "$T/bin/codex"
export D T PEER
cat > "$T/session.sh" <<'SESSION'
set -uo pipefail
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

payload() {   # payload <event> <tool> <json tool_input>
  EV=$1 TOOL=$2 TI=$3 CWD=$D python3 -c '
import json, os
d = {"session_id": "codex-test-session", "transcript_path": None, "cwd": os.environ["CWD"],
     "hook_event_name": os.environ["EV"], "model": "gpt-test", "permission_mode": "default",
     "turn_id": "t1"}
if os.environ["TOOL"]:
    d.update(tool_name=os.environ["TOOL"], tool_use_id="u1",
             tool_input=json.loads(os.environ["TI"]))
print(json.dumps(d))'
}
shell() { CMD=$1 python3 -c 'import json,os;print(json.dumps({"command":os.environ["CMD"]}))'; }
patch() {   # patch <verb> <relpath>
  V=$1 P=$2 python3 -c '
import json, os
t = "*** Begin Patch\n*** %s File: %s\n@@\n-a\n+z\n*** End Patch\n" % (os.environ["V"], os.environ["P"])
print(json.dumps({"command": t}))'
}

# pre <tool> <tool_input> -> sets RC, OUT, ERR
pre() {
  local pl; pl=$(payload PreToolUse "$1" "$2")
  OUT=$(cd "$D" && printf '%s' "$pl" | "$AB" hook-pretool --codex 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
# preraw <raw stdin> -> RC, OUT, ERR (for payloads no tool would build)
preraw() {
  OUT=$(cd "$D" && printf '%s' "$1" | "$AB" hook-pretool --codex 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
# shim <match> <action>: a python3 on PATH that runs <action> when its -c script
# contains <match>, and is the real python3 otherwise. Breaks one helper only.
REALPY=$(command -v python3)
shim() {
  mkdir -p "$T/shim"
  printf '#!/bin/bash\ncase "$2" in *%q*) %s ;; esac\nexec %q "$@"\n' "$1" "$2" "$REALPY" > "$T/shim/python3"
  chmod +x "$T/shim/python3"
}
# What Codex honours, and all the watchdog lets through: allow is exit 0 with
# nothing on stdout; deny is exit 2 with a reason on stderr and nothing on stdout.
decision() {
  if [ "$RC" = 0 ] && [ -z "$OUT" ]; then echo allow
  elif [ "$RC" = 2 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q '[^[:space:]]'; then echo deny
  else echo "unusable(rc=$RC out=$OUT)"; fi
}

echo 'SessionStart registers the session as codex and injects context'
OUT=$(cd "$D" && payload SessionStart '' '' | "$AB" hook-start --codex)
printf '%s' "$OUT" | python3 -c '
import json,sys; d=json.load(sys.stdin); h=d["hookSpecificOutput"]
assert set(d)=={"hookSpecificOutput"} and h["hookEventName"]=="SessionStart" and h["additionalContext"]' \
  && ok 'hook-start --codex: valid SessionStart output' || bad "hook-start output: $OUT"
ME=$(cd "$D" && "$AB" mine)
[ "$(sed -n 's/^agent: //p' "$ME")" = codex ] && ok 'session file says agent: codex' || bad "agent field in $ME"
(cd "$D" && "$AB" scope 'TID-0000 · codex test') >/dev/null
"$AB" list --include-self 2>/dev/null | grep -q 'TID-0000 · codex test' && ok 'scope shows on the board' || bad 'scope not on the board'

echo 'PreToolUse, shell: the hard gates refuse with exit 2 and a reason'
pre Bash "$(shell 'ansible-playbook site.yml')"
[ "$RC" = 2 ] && [ -n "$ERR" ] && ok '(a) un-wrapped ansible-playbook refused' || bad "(a) rc=$RC"
pre Bash "$(shell 'ansible-playbook site.yml --syntax-check')"
[ "$RC" = 0 ] && ok '    ansible-playbook --syntax-check passes' || bad "syntax-check rc=$RC"
pre Bash "$(shell 'ansible-vault edit vault.yml')"
[ "$RC" = 2 ] && [ -n "$ERR" ] && ok '(b) ansible-vault without the lease refused' || bad "(b) rc=$RC"
pre Bash "$(shell 'git add -A')"
[ "$RC" = 2 ] && [ -n "$ERR" ] && ok '(c) git add -A with a live peer refused' || bad "(c) rc=$RC"
pre Bash "$(shell 'git add mine.yml && git status')"
[ "$RC" = 0 ] && ok '    named-path git add passes' || bad "named add rc=$RC"
pre Bash '{"command": ["bash", "-lc", "git stash"]}'
[ "$RC" = 2 ] && ok '    argv form (bash -lc) is read too' || bad "argv rc=$RC"
pre Bash "$(shell $'apply_patch <<\'EOF\'\n*** Begin Patch\n*** Update File: mine.yml\n@@\n-b\n+c\n*** End Patch\nEOF\nansible-playbook site.yml')"
[ "$RC" = 2 ] && ok '    a patch inside a shell call does not hide the command' || bad "shell patch rc=$RC"

pl=$(payload PreToolUse Bash "$(shell 'ansible-playbook site.yml')")
(cd "$D" && printf '%s' "$pl" | AGENT_BOARD_HOOK_LOG="$T/hooks.log" "$AB" hook-pretool --codex) 2>/dev/null; RC=$?
[ "$RC" = 2 ] && grep -q 'codex hook-pretool.*ansible-playbook site.yml' "$T/hooks.log" \
  && ok '    AGENT_BOARD_HOOK_LOG records the payload, and the gate still refuses' || bad "hook log rc=$RC"

echo 'Fail closed: a payload or parser the gate cannot read is refused (review #2)'
preraw '{'
[ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'could not check' && ok 'malformed JSON: refused' || bad "malformed rc=$RC"
preraw '{"cwd":"/","tool_input":{"command":"git stash"}}'
[ "$RC" = 2 ] && ok 'no tool_name: refused' || bad "no tool_name rc=$RC"
pre Bash '{}'
[ "$RC" = 2 ] && ok 'Bash with no command: refused' || bad "missing command rc=$RC"
pre Bash '{"command": {"command": "git stash"}}'
[ "$RC" = 2 ] && ok 'Bash with a command object: refused' || bad "command object rc=$RC"
pre Bash '{"command": ["git", 1]}'
[ "$RC" = 2 ] && ok 'Bash with a bad argv list: refused' || bad "bad argv rc=$RC"
pre Read '{"file_path": "x"}'
[ "$RC" = 0 ] && ok '    a tool with no command (Read) still passes' || bad "Read rc=$RC"
shim 'import json, os, shlex, sys' 'exit 1'
OLDPATH=$PATH; PATH="$T/shim:$PATH"
pre Bash "$(shell 'git status')"
PATH=$OLDPATH
[ "$RC" = 2 ] && ok 'command parser process fails: refused, even for a harmless command' || bad "parser fail rc=$RC"
shim 'markers = (' 'exit 1'
PATH="$T/shim:$PATH"
pre apply_patch "$(patch Update mine.yml)"
PATH=$OLDPATH
[ "$RC" = 2 ] && ok 'patch parser process fails: refused' || bad "patch parser fail rc=$RC"

shim 'out, delim = [], None' 'exit 1'
PATH="$T/shim:$PATH"
pre Bash "$(shell 'git status')"
PATH=$OLDPATH
[ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'scanner failed' && ok 'command scanner fails: refused (recheck R2)' || bad "scanner fail rc=$RC"
mkdir -p "$T/grepshim"; printf '#!/bin/bash\nexit 2\n' > "$T/grepshim/grep"; chmod +x "$T/grepshim/grep"
OUT=$(cd "$D" && payload PreToolUse Bash "$(shell 'git stash')" | AB_HOOK_CHILD=1 PATH="$T/grepshim:$PATH" "$AB" hook-pretool --codex 2>"$T/err"); RC=$?
[ "$RC" = 2 ] && grep -q 'pattern check failed' "$T/err" && ok 'a failing grep inside the gate: refused' || bad "grep fail rc=$RC $(cat "$T/err")"
# Claude side of hook_decide: a renderer that fails must not leave a silent allow.
shim 'permissionDecisionReason": os.environ' 'exit 1'
PATH="$T/shim:$PATH"
pl=$(payload PreToolUse apply_patch "$(patch Update shared.yml)")
OUT=$(cd "$D" && printf '%s' "$pl" | "$AB" hook-pretool 2>"$T/err"); RC=$?
PATH=$OLDPATH
[ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q 'uncommitted changes' "$T/err" && ok 'deny renderer fails (Claude form): exit 2 with the reason (recheck R2)' || bad "renderer fail rc=$RC out=$OUT"

echo 'Patch headers are read as Codex reads them (review #1)'
ind() { V=$1 P=$2 python3 -c '
import json, os
t = "*** Begin Patch\n  *** %s File: %s  \n@@\n-a\n+z\n*** End Patch\n" % (os.environ["V"], os.environ["P"])
print(json.dumps({"command": t}))'; }
pre apply_patch "$(ind Update shared.yml)"
[ "$(decision)" = deny ] && ok 'indented header on a peer-held file: deny' || bad "indented overlap: rc=$RC $OUT"
pre apply_patch "$(ind Update vault.yml)"
[ "$(decision)" = deny ] && ok 'indented header on a vault file: deny' || bad "indented vault: rc=$RC $OUT"
pre apply_patch '{"command": "*** Begin Patch\n*** Frobnicate File: shared.yml\n*** End Patch\n"}'
[ "$RC" = 2 ] && ok 'a patch that names no file the hook can read: refused' || bad "no-path patch rc=$RC"
pre apply_patch '{"command": "*** Begin Patch\n*** Update File:   \n*** End Patch\n"}'
[ "$RC" = 2 ] && ok 'a header with an empty path: refused' || bad "empty path rc=$RC"
# Recheck R1: Codex trims the line, then takes everything after the marker as is.
printf 'x\n' > "$D/ leading.yml"; printf 'x\n' > "$D/leading.yml"
printf 'peer\n' >> "$D/ leading.yml"; printf '%s\t%s\n' "$D" ' leading.yml' >> "$AGENT_BOARD_DIR/paths/$PEER"
pre apply_patch '{"command": "*** Begin Patch\n*** Update File:  leading.yml\n@@\n-x\n+y\n*** End Patch\n"}'
[ "$(decision)" = deny ] && ok 'a file name that starts with a space is gated as that file (recheck R1)' || bad "leading space: rc=$RC $OUT"
pre apply_patch '{"command": "*** Begin Patch\n*** Update File: leading.yml\n@@\n-x\n+y\n*** End Patch\n"}'
[ "$(decision)" = allow ] && ok '    and the name without the space is a different, free file' || bad "no-space: rc=$RC $ERR"
pre Bash "$(shell "grep -n '*** Begin Patch' notes.txt")"
[ "$RC" = 0 ] && ok '    a shell command that only mentions the marker passes' || bad "mention rc=$RC"

echo 'Only pure patch tools skip the command gates (review #5)'
HP=$'apply_patch <<\'EOF\'\n*** Begin Patch\n*** Update File: mine.yml\n@@\n-b\n+c\n*** End Patch\nEOF\ngit stash'
pre functions.exec_command "$(shell "$HP")"
[ "$RC" = 2 ] && ok 'unknown tool name, patch + git stash: refused' || bad "unknown tool rc=$RC"
pre functions.exec_command "$(shell 'git stash')"
[ "$RC" = 2 ] && ok 'unknown tool name, git stash alone: refused' || bad "unknown alone rc=$RC"

echo 'PreToolUse, apply_patch: the file gates answer in a form Codex accepts'
pre apply_patch "$(patch Update vault.yml)"
[ "$(decision)" = deny ] && ok 'patch to a vault file without the lease: deny' || bad "vault patch: $OUT"
pre apply_patch "$(patch Update mine.yml)"
[ "$(decision)" = allow ] && ok 'patch to a file nobody else holds: allowed (silent)' || bad "mine patch: $OUT"
pre apply_patch "$(patch Update shared.yml)"
[ "$(decision)" = deny ] && printf '%s' "$ERR" | grep -q 'allow-edit' \
  && ok 'patch to a peer-held file: deny, not ask, and names allow-edit' || bad "overlap: $OUT"
(cd "$D" && "$AB" allow-edit shared.yml) >/dev/null
pre apply_patch "$(patch Update shared.yml)"
[ "$(decision)" = allow ] && ok 'after allow-edit: allowed once' || bad "after allow-edit: $OUT"
pre apply_patch "$(patch Update shared.yml)"
[ "$(decision)" = deny ] && ok 'allow-edit is spent after one use' || bad "spent: $OUT"
(cd "$D" && "$AB" allow-edit shared.yml) >/dev/null
pl=$(payload PreToolUse apply_patch "$(patch Update shared.yml)")
mkdir -p "$T/race"
for i in $(seq 1 20); do
  (cd "$D" && printf '%s' "$pl" | "$AB" hook-pretool --codex >/dev/null 2>&1; echo $? >"$T/race/$i") &
done
wait
n=0; for i in $(seq 1 20); do [ "$(cat "$T/race/$i")" = 0 ] && n=$((n+1)); done
[ "$n" = 1 ] && ok 'one grant, 20 concurrent edits: exactly one passes (review #4)' || bad "race: $n passed"
pre Edit "$(patch Update shared.yml)"
[ "$(decision)" = deny ] && ok 'the same patch under the Edit tool name is gated too' || bad "Edit alias: $OUT"

# Recheck R5: a sweep must leave a live session's grant lock in place. Hold the
# lock, sweep, and check that a second taker still waits for the holder.
(cd "$D" && "$AB" allow-edit shared.yml mine.yml) >/dev/null
GF=$(ls "$AGENT_BOARD_DIR"/locks/allow-edit.* 2>/dev/null | grep -v '\.lock$' | head -1)
python3 - "$GF.lock" <<'PY' &
import fcntl, sys, time
with open(sys.argv[1], "a") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX); open(sys.argv[1] + ".held", "w").close(); time.sleep(3)
PY
HOLDER=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$GF.lock.held" ] && break; sleep 0.2; done
"$AB" sweep >/dev/null 2>&1
[ -e "$GF.lock" ] && ok 'sweep keeps the lock file of a live session (R5)' || bad 'sweep removed a live lock'
s0=$(date +%s%N)
python3 -c 'import fcntl,sys; fcntl.flock(open(sys.argv[1],"a"), fcntl.LOCK_EX)' "$GF.lock"
w=$(( ($(date +%s%N) - s0) / 1000000 ))
wait "$HOLDER"
[ "$w" -gt 1000 ] && ok "    a second taker after the sweep still waits for the holder (${w}ms)" || bad "lock split: waited ${w}ms"
mkdir -p "$AGENT_BOARD_DIR/locks"; : > "$AGENT_BOARD_DIR/locks/allow-edit.999999"; : > "$AGENT_BOARD_DIR/locks/allow-edit.999999.lock"
"$AB" sweep >/dev/null 2>&1
[ ! -e "$AGENT_BOARD_DIR/locks/allow-edit.999999" ] && [ ! -e "$AGENT_BOARD_DIR/locks/allow-edit.999999.lock" ] \
  && ok '    a dead session'"'"'s grant and lock are both swept' || bad 'dead grant/lock left'
rm -f "$GF" "$GF.lock.held"

echo 'The Codex gate is bounded: a hang, a crash or bad output is a refusal (review #3)'
shim 'import json, os, shlex, sys' 'sleep 30'
PATH="$T/shim:$PATH"
s0=$(date +%s)
OUT=$(cd "$D" && payload PreToolUse Bash "$(shell 'git status')" | AGENT_BOARD_HOOK_BUDGET=2 "$AB" hook-pretool --codex 2>"$T/err"); RC=$?
el=$(( $(date +%s) - s0 ))
PATH=$OLDPATH
[ "$RC" = 2 ] && grep -q 'budget' "$T/err" && [ "$el" -lt 10 ] && ok "a hung gate is refused after its budget (${el}s)" || bad "hang rc=$RC el=$el"
# Walk up to the gate process (the child of `timeout`) and kill it outright.
shim 'import json, os, shlex, sys' 'p=$PPID; while [ "$p" -gt 1 ]; do q=$(ps -o ppid= -p "$p" | tr -d " "); if [ "$(ps -o comm= -p "$q")" = timeout ]; then kill -KILL "$p"; exit 1; fi; p=$q; done; exit 1'
PATH="$T/shim:$PATH"
pre Bash "$(shell 'git status')"
PATH=$OLDPATH
[ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'was killed' && ok 'a gate killed mid-run is refused' || bad "crash rc=$RC $ERR"
# The parent passes on only "exit 0, no stdout" and "exit 2 with a reason". A
# stand-in for the gate (via a fake timeout that runs a script instead) shows it
# refusing the shapes Codex would take as a non-blocking error (recheck R3).
fake_gate() {   # fake_gate <bash body>: the child's whole behaviour
  mkdir -p "$T/fakegate"
  printf '#!/bin/bash\ncat >/dev/null\n%s\n' "$1" > "$T/fakegate/timeout"
  chmod +x "$T/fakegate/timeout"
}
gate_with() {   # gate_with <bash body> -> RC OUT ERR, from the real parent
  fake_gate "$1"
  OUT=$(cd "$D" && payload PreToolUse Bash "$(shell 'git status')" | PATH="$T/fakegate:$PATH" "$AB" hook-pretool --codex 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
gate_with 'echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"x\"},\"continue\":false}"; exit 0'
[ "$(decision)" = deny ] && printf '%s' "$ERR" | grep -q 'stdout' && ok 'a JSON answer with extra fields is refused afresh, not forwarded (R3)' || bad "json+continue: rc=$RC out=$OUT"
gate_with 'echo not-json; exit 0'
[ "$(decision)" = deny ] && ok 'plain non-JSON stdout is refused' || bad "non-json: rc=$RC"
gate_with 'printf "  \n" >&2; exit 2'
[ "$(decision)" = deny ] && printf '%s' "$ERR" | grep -q 'without a reason' && ok 'exit 2 with a blank reason is refused with a reason of its own (R3)' || bad "blank exit2: rc=$RC err=$ERR"
gate_with 'exit 127'
[ "$(decision)" = deny ] && printf '%s' "$ERR" | grep -q 'exit 127' && ok 'timeout missing (exit 127) is refused, not let through' || bad "127: rc=$RC"
gate_with 'exit 0'
[ "$(decision)" = allow ] && ok '    a clean allow passes' || bad "clean allow: rc=$RC out=$OUT"
gate_with 'echo "refused for a reason" >&2; exit 2'
[ "$(decision)" = deny ] && [ "$ERR" = 'refused for a reason' ] && ok '    a refusal with a reason passes through unchanged' || bad "exit2 passthrough: $ERR"
# R4: the parent itself does no work that can stall after the child: no python.
shim 'import json' 'sleep 30'
PATH="$T/shim:$PATH"
fake_gate 'echo "refused" >&2; exit 2'
s0=$(date +%s)
OUT=$(cd "$D" && printf '{}' | PATH="$T/fakegate:$T/shim:$PATH" "$AB" hook-pretool --codex 2>"$T/err"); RC=$?
el=$(( $(date +%s) - s0 ))
PATH=$OLDPATH
[ "$RC" = 2 ] && [ "$el" -lt 5 ] && ok "the parent answers without python, even when python hangs (${el}s) (R4)" || bad "parent stall rc=$RC el=$el"
grep -q 'python3' <(sed -n '/AB_HOOK_CHILD:-}" \]; then/,/^    fi$/p' "$AB") && bad 'the watchdog parent calls python3' || ok '    the watchdog parent block has no python3 call'
OUT=$(cd "$D" && payload PreToolUse Bash "$(shell 'git status')" | AGENT_BOARD_HOOK_BUDGET=9999 "$AB" hook-pretool --codex 2>"$T/err"); RC=$?
[ "$RC" = 0 ] && ok '    an out-of-range budget is clamped, and the gate still runs' || bad "budget clamp rc=$RC"

echo 'PostToolUse records the files a patch touched'
printf 'c\n' > "$D/mine.yml"
(cd "$D" && payload PostToolUse apply_patch "$(patch Update mine.yml)" | "$AB" hook-posttool --codex)
grep -qxF "$D	mine.yml" "$AGENT_BOARD_DIR/paths/$PPID" && ok 'mine.yml claimed for this session' || bad 'no claim recorded'

echo 'Stop delivers the inbox as a block with a reason, once'
# Posted by the peer, in post_msg's format: anything run inside this session's
# process tree would be this session, and a message to yourself is not delivered.
e=$(date +%s)
cat > "$AGENT_BOARD_DIR/messages/$e.$PEER.1.md" <<EOF
from_pid: $PEER
from_name: peer
from_agent: claude
to: $PPID
repo: $D
epoch: $e
time: $(date +%H:%M)

hello from the peer
EOF
OUT=$(cd "$D" && payload Stop '' '' | "$AB" hook-stop --codex)
printf '%s' "$OUT" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert set(d)=={"decision","reason"} and d["decision"]=="block" and "hello from the peer" in d["reason"]' \
  && ok 'Stop: {"decision":"block","reason":...} carries the message' || bad "stop: $OUT"
OUT=$(cd "$D" && payload Stop '' '' | "$AB" hook-stop --codex)
[ -z "$OUT" ] && ok 'the next Stop is silent (no loop)' || bad "second stop: $OUT"

echo 'SessionEnd is fast and leaves the session DONE'
s=$(date +%s%N)
(cd "$D" && printf '{"session_id":"x","cwd":"%s","hook_event_name":"SessionEnd","reason":"other","transcript_path":null}' "$D" | "$AB" hook-end --codex)
ms=$(( ($(date +%s%N) - s) / 1000000 ))
[ "$ms" -lt 1000 ] && ok "hook-end --codex took ${ms}ms (< 1000ms)" || bad "hook-end took ${ms}ms"
[ "$(sed -n 's/^status: //p' "$ME")" = DONE ] && ok 'status DONE' || bad 'status not DONE'

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
SESSION
"$T/bin/codex" -c 'bash "$1"; rc=$?; exit "$rc"' codex "$T/session.sh"
rc=$?

# The Claude side of the same hooks is covered by the other suites in test/.
exit "$rc"

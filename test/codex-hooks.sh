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
decision() { printf '%s' "$OUT" | python3 -c '
import json, sys
s = sys.stdin.read().strip()
if not s: print("allow"); sys.exit()
d = json.loads(s)
h = d["hookSpecificOutput"]
# What Codex accepts: deny with a non-empty reason, nothing else.
assert set(d) == {"hookSpecificOutput"}, d
assert set(h) <= {"hookEventName", "permissionDecision", "permissionDecisionReason"}, h
assert h["hookEventName"] == "PreToolUse"
assert h["permissionDecision"] == "deny" and h["permissionDecisionReason"].strip()
print("deny")' 2>/dev/null || echo unparseable; }

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

echo 'PreToolUse, apply_patch: the file gates answer in a form Codex accepts'
pre apply_patch "$(patch Update vault.yml)"
[ "$(decision)" = deny ] && ok 'patch to a vault file without the lease: deny' || bad "vault patch: $OUT"
pre apply_patch "$(patch Update mine.yml)"
[ "$(decision)" = allow ] && ok 'patch to a file nobody else holds: allowed (silent)' || bad "mine patch: $OUT"
pre apply_patch "$(patch Update shared.yml)"
[ "$(decision)" = deny ] && printf '%s' "$OUT" | grep -q 'allow-edit' \
  && ok 'patch to a peer-held file: deny, not ask, and names allow-edit' || bad "overlap: $OUT"
(cd "$D" && "$AB" allow-edit shared.yml) >/dev/null
pre apply_patch "$(patch Update shared.yml)"
[ "$(decision)" = allow ] && ok 'after allow-edit: allowed once' || bad "after allow-edit: $OUT"
pre apply_patch "$(patch Update shared.yml)"
[ "$(decision)" = deny ] && ok 'allow-edit is spent after one use' || bad "spent: $OUT"
pre Edit "$(patch Update shared.yml)"
[ "$(decision)" = deny ] && ok 'the same patch under the Edit tool name is gated too' || bad "Edit alias: $OUT"

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

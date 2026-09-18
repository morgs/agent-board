#!/bin/bash
# Verifies the per-repo gates in bin/agentboard.
#
# Fully self-contained: it builds four throwaway git repos named notes, deploy,
# tools and app (the policy is chosen by basename) inside a throwaway
# AGENT_BOARD_DIR,
# so it neither reads nor writes the real board or the real checkouts. That is what
# lets it make files genuinely dirty and genuinely vault-encrypted, which is the
# only honest way to test the file-level gates. Exit 0 if every case matched.
#
#   ~/agent-board/test/policy-matrix.sh
#
# Note the shape of the cases below: each command is passed as a single-quoted
# argument, never written in command position. That matters — the gates scan the
# command line they are given, and a harness that spells `git add -A` at the start
# of a line gets blocked by the thing it is trying to test.
set -uo pipefail

AB=${AB:-$HOME/agent-board/bin/agentboard}
export AGENT_BOARD_DIR AGENT_BOARD_CC_SESSIONS
# physical path: git reports checkout roots physically, and TMPDIR is a symlink
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentboard-test.XXXXXX")" && pwd -P)
AGENT_BOARD_DIR="$T/board"
AGENT_BOARD_CC_SESSIONS="$T/cc"      # keeps the tests out of ~/.claude
mkdir -p "$AGENT_BOARD_DIR" "$AGENT_BOARD_CC_SESSIONS"
# The policies under test are configuration now, not a case statement, so the suite
# states them itself rather than relying on whatever this machine happens to use.
cat > "$AGENT_BOARD_DIR/workspace.local" <<'WS'
[content]
notes
[shared-main]
infra
tools
board
[no-branch]
infra
WS
FAKES=()

cleanup() {
  for p in ${FAKES+"${FAKES[@]}"}; do kill "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

mkrepo() {   # mkrepo <name>
  local d="$T/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'x\n' > "$d/README.md"
  git -C "$d" add README.md; git -C "$d" commit -qm init
  printf '%s' "$d"
}

fake() {   # fake <dir> <scope> -> pid
  sleep 3000 </dev/null >/dev/null 2>&1 &
  local p=$!
  disown "$p" 2>/dev/null   # else bash prints "Terminated" for each one at cleanup
  FAKES+=("$p")
  "$AB" claim --pid "$p" --agent codex --cwd "$1" --scope "$2" >/dev/null
  printf '%s' "$p"
}

# What the PostToolUse hook would have recorded for that agent, plus a real dirty
# file so the claim survives the "still uncommitted?" narrowing on read.
fake_writes() {   # fake_writes <pid> <repo> <relpath>
  mkdir -p "$(dirname "$2/$3")"
  printf 'edited by a peer\n' >> "$2/$3"
  printf '%s\t%s\n' "$2" "$3" >> "$AGENT_BOARD_DIR/paths/$1"
}

fake_hold() { sed -i '' "s|^hold: .*|hold: $2|" "$AGENT_BOARD_DIR/sessions/$1.md"; }

pass=0; fail=0
run() {   # run <cwd> <command> <expected exit>
  local cwd=$1 command=$2 want=$3 got payload
  payload=$(CWD="$cwd" CMD="$command" python3 -c \
    'import json,os;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}))')
  printf '%s' "$payload" | (cd "$cwd" && "$AB" hook-pretool) >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  ok    (%s) %s\n' "$got" "$command"
  else
    fail=$((fail+1)); printf '  FAIL  want %s got %s: %s\n' "$want" "$got" "$command"
  fi
}

edit() {   # edit <cwd> <file> <allow|deny|ask>
  local cwd=$1 file=$2 want=$3 got out payload
  payload=$(CWD="$cwd" P="$file" python3 -c \
    'import json,os;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":"Edit","tool_input":{"file_path":os.environ["P"]}}))')
  out=$(printf '%s' "$payload" | (cd "$cwd" && "$AB" hook-pretool) 2>/dev/null)
  if [ -z "$out" ]; then got=allow
  else got=$(printf '%s' "$out" | python3 -c \
    'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null || echo unparseable)
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  ok    (%s) edit %s\n' "$got" "${file#"$cwd"/}"
  else
    fail=$((fail+1)); printf '  FAIL  want %s got %s: edit %s\n' "$want" "$got" "${file#"$cwd"/}"
  fi
}

# run() reads the exit status, which cannot tell allow from ask — both are 0. This
# reads the decision itself, for the gates whose answer is "pause", not "no".
decide() {   # decide <cwd> <command> <allow|deny|ask>
  local cwd=$1 command=$2 want=$3 got out payload
  payload=$(CWD="$cwd" CMD="$command" python3 -c \
    'import json,os;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}))')
  out=$(printf '%s' "$payload" | (cd "$cwd" && "$AB" hook-pretool) 2>/dev/null)
  if [ -z "$out" ]; then got=allow
  else got=$(printf '%s' "$out" | python3 -c \
    'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null || echo unparseable)
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  ok    (%s) %s\n' "$got" "$command"
  else
    fail=$((fail+1)); printf '  FAIL  want %s got %s: %s\n' "$want" "$got" "$command"
  fi
}

A=$(mkrepo notes)
D=$(mkrepo infra)
S=$(mkrepo tools)
B=$(mkrepo board)
O=$(mkrepo app)

# A vault file, as git sees one: encrypted in HEAD. Deliberately larger than a
# 64KB pipe buffer — a small one reads back in a single write and hides the
# SIGPIPE class of bug in the header check entirely.
mkdir -p "$D/group_vars"
{ printf '$ANSIBLE_VAULT;1.1;AES256\n'; for i in $(seq 4000); do printf '3132333435363738393a3b3c3d3e3f4041424344454647484950\n'; done; } > "$D/vault.yml"
printf 'plain: true\n' > "$D/group_vars/all.yml"
printf -- '- hosts: all\n' > "$D/site.yml"
git -C "$D" add vault.yml group_vars/all.yml site.yml
git -C "$D" commit -qm 'vault + friends'

PB=$(fake "$B" 'the wins panel')
PA=$(fake "$A" 'writing its own session note')
PD=$(fake "$D" 'roles/metrics')
PS=$(fake "$S" 'monthly earnings send')
PO=$(fake "$O" 'widgets module')

echo 'notes (content) — ordinary catchup/wrap traffic passes'
run "$A" 'git pull --ff-only' 0
run "$A" 'git status' 0
run "$A" 'git add sessions/2026-09-07-agent-board.md' 0
run "$A" 'git add sessions/x.md && git commit -m msg' 0
run "$A" 'git push' 0
run "$A" 'git commit -m wip' 0
echo 'notes — whole-tree ops still blocked while a peer is live'
run "$A" 'git commit -am wip' 2
run "$A" 'git commit -a -m wip' 2
run "$A" 'git add -A' 2
run "$A" 'git add .' 2
run "$A" 'git stash' 2
run "$A" 'git reset --hard' 2
echo 'notes — the file gate does not apply (nothing collides here)'
edit "$A" "$A/sessions/mine.md" allow

echo
echo 'deploy (shared-main) — named-path commits pass, whole-tree does not'
run "$D" 'git add site.yml && git commit -m "site: fix"' 0
run "$D" 'git push' 0
run "$D" 'git commit -am wip' 2
run "$D" 'git add -A' 2
echo 'deploy — branch switching is blocked whether or not anyone else is live'
run "$D" 'git switch -c experiment/x' 2
run "$D" 'git checkout -b experiment/x' 2
run "$D" 'git checkout main' 2
run "$D" 'git worktree add -b experiment/x ../infra-x main' 0
echo
echo 'tools (shared-main) — the same file-level model as deploy'
run "$S" 'git add docs/x.md && git commit -m "docs: x"' 0
run "$S" 'git push' 0
run "$S" 'git commit -am wip' 2
run "$S" 'git add -A' 2
# The branch gate is deploy's alone: it exists because Ansible ships that working
# tree. Keying it on shared-main instead of the name would wrongly block these.
echo 'tools — branching is allowed: nothing deploys from this tree'
run "$S" 'git switch -c experiment/x' 0
run "$S" 'git checkout -b experiment/x' 0
run "$S" 'git checkout main' 0
echo
# The board's own repo is shared-main for the same reason, and on the same
# evidence: two agents committed straight to main within ten minutes with the one
# binary dirty in both their hands. The file is the unit here, not the checkout,
# and it is not content — agent-board changes concentrate in bin/agentboard
# rather than in a uniquely-named file per session.
echo 'agent-board (shared-main) — one shared binary, so the file is the unit'
run "$B" 'git add bin/agentboard && git commit -m "wins panel"' 0
run "$B" 'git push' 0
run "$B" 'git commit -am wip' 2
run "$B" 'git add .' 2
run "$B" 'git switch -c experiment/x' 0

echo 'deploy — ansible goes through the lock'
run "$D" 'ansible-playbook site.yml -l staging' 2
run "$D" 'sudo ansible-playbook site.yml' 2
run "$D" '~/agent-board/bin/deploylock ansible-playbook site.yml -l staging' 0
run "$D" 'ansible-playbook site.yml --syntax-check' 0
run "$D" 'ansible-playbook site.yml --list-hosts' 0
run "$D" 'ansible-playbook site.yml --check' 2
run "$D" 'echo "remember to run ansible-playbook later"' 0

echo
echo 'deploy — vault edits need the lease'
run "$D" 'ansible-vault edit vault.yml' 2
run "$D" 'ansible-vault decrypt vault.yml' 2
run "$D" 'ansible-vault rekey vault.yml' 2
run "$D" 'grep -c . vault.yml' 0
edit "$D" "$D/vault.yml" deny
"$AB" vault take vault.yml >/dev/null 2>&1
echo '  (lease now held by this session)'
run "$D" 'ansible-vault edit vault.yml' 0
edit "$D" "$D/vault.yml" allow
echo 'deploy — but never commit one that is sitting decrypted'
printf 'secret: hunter2\n' > "$D/vault.yml"
run "$D" 'git add vault.yml && git commit -m "vault: rotate"' 2
git -C "$D" checkout -q -- vault.yml
run "$D" 'git add vault.yml && git commit -m "vault: rotate"' 0
"$AB" vault free >/dev/null 2>&1
run "$D" 'ansible-vault edit vault.yml' 2

echo
echo 'deploy — the file gate: overlap pauses, everything else passes'
edit "$D" "$D/site.yml" allow
fake_writes "$PD" "$D" group_vars/all.yml
edit "$D" "$D/group_vars/all.yml" ask
edit "$D" "$D/site.yml" allow
git -C "$D" add group_vars/all.yml && git -C "$D" commit -qm 'peer work landed'
echo '  (their change is committed, so the claim lapses on its own)'
edit "$D" "$D/group_vars/all.yml" allow

echo
echo 'app (branch-pr) — a peer that is not changing the checkout blocks nothing'
run "$O" 'git commit -m wip' 0
run "$O" 'git push' 0
run "$O" 'git rebase main' 0
echo 'app — a peer holding it blocks git, but not the remedy'
fake_hold "$PO" "$O"
run "$O" 'git commit -m wip' 2
run "$O" 'git push' 2
run "$O" 'git checkout -b feat/x' 2
run "$O" 'git rebase -i main' 2
run "$O" 'git worktree add -b feat/x ../app-x main' 0
run "$O" 'git worktree list' 0
run "$O" 'git worktree remove ../app-x' 2
run "$O" 'git status' 0
run "$O" 'git diff' 0
run "$O" 'AGENT_BOARD_OVERRIDE=1 git commit -m wip' 0
echo 'app — a peer with uncommitted files counts as holding, even without `hold`'
fake_hold "$PO" '-'
run "$O" 'git commit -m wip' 0
fake_writes "$PO" "$O" addons/widgets/__init__.py
run "$O" 'git commit -m wip' 2
echo 'app — the file gate does not apply here; the checkout is the unit'
edit "$O" "$O/addons/widgets/__init__.py" allow

echo
echo 'dev environments — a box someone else is mid-test on'
PE=$(fake "$O" 'sandbox overlay test')
mkdir -p "$AGENT_BOARD_DIR/locks/env/sandbox.lease"
printf 'pid: %s\nname: sandbox-tester\nfor: widgets overlay\nsince: now\n' "$PE" \
  > "$AGENT_BOARD_DIR/locks/env/sandbox.lease/owner"
echo '  (a peer holds sandbox; nothing holds testbed)'
run    "$D" '~/agent-board/bin/deploylock ansible-playbook refresh.yml -l sandbox' 2
run    "$D" 'ansible-playbook site.yml -l testbed' 2   # the deploy lock, not this gate
decide "$O" 'ssh admin@sandbox.example.internal "sudo systemctl restart theapp"' ask
decide "$O" 'psql -h sandbox -d sandbox-db -c "select 1"' ask
echo '  the gate is about the box, not the repo, so it fires anywhere'
decide "$T" 'ssh admin@sandbox.example.internal uptime' ask
echo '  and only on that box, whole-word'
decide "$O" 'ssh admin@testbed.example.internal uptime' allow
decide "$O" 'git log --grep sandboxberry' allow
decide "$O" 'echo sandboxs' allow
echo '  the holder is not gated out of their own test'
mkdir -p "$AGENT_BOARD_DIR/locks/env/testbed.lease"
printf 'pid: %s\nname: me\nfor: x\nsince: now\n' "$$" > "$AGENT_BOARD_DIR/locks/env/testbed.lease/owner"
"$AB" claim --pid "$$" --agent claude --cwd "$O" --scope 'testing testbed' >/dev/null
decide "$O" 'ssh admin@testbed.example.internal uptime' allow
run    "$D" '~/agent-board/bin/deploylock ansible-playbook refresh.yml -l testbed' 0
echo '  a freed lease gates nothing'
rm -rf "$AGENT_BOARD_DIR/locks/env/sandbox.lease"
decide "$O" 'ssh admin@sandbox.example.internal uptime' allow

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

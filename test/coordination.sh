#!/bin/bash
# Verifies the coordination primitives in bin/agentboard: hold/release, the observed
# file sets, check's per-policy verdict, the vault lease and the worktree report.
#
# Self-contained, like policy-matrix.sh: throwaway repos named notes, deploy and
# app (policy is chosen by basename) inside a throwaway AGENT_BOARD_DIR.
#
#   ~/agent-board/test/coordination.sh
set -uo pipefail

AB=${AB:-$HOME/agent-board/bin/agentboard}
export AGENT_BOARD_DIR AGENT_BOARD_CC_SESSIONS
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentboard-coord.XXXXXX")" && pwd -P)
AGENT_BOARD_DIR="$T/board"
AGENT_BOARD_CC_SESSIONS="$T/cc"
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

pass=0; fail=0
want() {     # want <label> <expected substring> <actual>
  case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok    %s\n' "$1" ;;
    *) fail=$((fail+1)); printf '  FAIL  %s\n          wanted: %s\n          got:    %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' '|')" ;;
  esac
}
wantnot() {  # wantnot <label> <forbidden substring> <actual>
  case "$3" in *"$2"*) fail=$((fail+1)); printf '  FAIL  %s\n          must not contain: %s\n          got: %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' '|')" ;;
    *) pass=$((pass+1)); printf '  ok    %s\n' "$1" ;;
  esac
}

mkrepo() {
  local d="$T/$1"
  mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'x\n' > "$d/README.md"; git -C "$d" add README.md; git -C "$d" commit -qm init
}

fake() {   # fake <dir> <scope> -> pid
  { trap - EXIT; exec sleep 3000; } </dev/null >/dev/null 2>&1 &
  local p=$!
  disown "$p" 2>/dev/null
  FAKES+=("$p")
  "$AB" claim --pid "$p" --agent codex --cwd "$1" --scope "$2" >/dev/null
  printf '%s' "$p"
}
fake_named() {   # fake_named <dir> <name> -> pid
  local p; p=$(fake "$1" '-')
  sed -i '' "s|^name: .*|name: $2|" "$AGENT_BOARD_DIR/sessions/$p.md"
  printf '%s' "$p"
}
fake_writes() {   # fake_writes <pid> <repo> <relpath>
  mkdir -p "$(dirname "$2/$3")"
  printf 'peer edit\n' >> "$2/$3"
  printf '%s\t%s\n' "$2" "$3" >> "$AGENT_BOARD_DIR/paths/$1"
}

mkrepo notes; mkrepo infra; mkrepo app
A="$T/notes"; D="$T/infra"; O="$T/app"
# >64KB on purpose: see the note in policy-matrix.sh. A small vault fixture let
# a SIGPIPE bug in the header check ship, and it exempted only the big files.
{ printf '$ANSIBLE_VAULT;1.1;AES256\n'; for i in $(seq 4000); do printf '3132333435363738393a3b3c3d3e3f4041424344454647484950\n'; done; } > "$D/vault.yml"
printf 'plain: true\n' > "$D/group_vars.yml"
printf -- '- hosts: all\n' > "$D/site.yml"
git -C "$D" add .; git -C "$D" commit -qm 'vault + friends'

echo 'check — one verdict per policy'
want 'content says there is nothing to coordinate' 'nothing to coordinate' "$(cd "$A" && "$AB" check)"
want 'branch-pr with nobody live is free'          'free — branch and PR'   "$(cd "$O" && "$AB" check)"
want 'shared-main with nobody live says so'        'no other agents'        "$(cd "$D" && "$AB" check)"
want 'shared-main reports the vault lease'         'vault: free, 1'         "$(cd "$D" && "$AB" check)"
# The header check must not depend on blob size: a vault file larger than the
# pipe buffer is still a vault file.
want 'a vault file bigger than a pipe buffer is still counted' 'free, 1 encrypted' "$(cd "$D" && "$AB" check)"
printf 'now decrypted\n' > "$D/vault.yml"
git -C "$D" add vault.yml
want 'and staging it decrypted does not drop it from the list' 'free, 1 encrypted' "$(cd "$D" && "$AB" check)"
git -C "$D" reset -q; git -C "$D" checkout -q -- vault.yml

echo
echo 'hold / release — the whole branch-pr protocol'
PO=$(fake_named "$O" peer-app)
want 'a live peer that is not changing it does not take it' 'free — branch and PR' "$(cd "$O" && "$AB" check)"
sed -i '' "s|^hold: .*|hold: $O|" "$AGENT_BOARD_DIR/sessions/$PO.md"
want 'a peer holding it makes the checkout TAKEN'  'TAKEN by ' "$(cd "$O" && "$AB" check)"
want 'and says which peer'                        'peer-app (codex)' "$(cd "$O" && "$AB" check)"
want 'and names the remedy'                        'git worktree add -b'    "$(cd "$O" && "$AB" check)"
sed -i '' "s|^hold: .*|hold: -|" "$AGENT_BOARD_DIR/sessions/$PO.md"
want 'released, it is free again'                  'free — branch and PR'   "$(cd "$O" && "$AB" check)"
fake_writes "$PO" "$O" addons/widgets/__init__.py
want 'a peer with uncommitted work holds it implicitly' 'peer-app (codex)' "$(cd "$O" && "$AB" check)"
git -C "$O" add -A >/dev/null; git -C "$O" commit -qm 'peer landed it'
want 'and the implicit hold lapses when they commit' 'free — branch and PR'  "$(cd "$O" && "$AB" check)"
want 'my own hold reports back'                    'holding app @ main' "$(cd "$O" && "$AB" hold)"
want 'release with a clean tree says so'           'app is free'     "$(cd "$O" && "$AB" release)"
printf 'mine\n' > "$O/mine.txt"
(cd "$O" && "$AB" hold >/dev/null)
printf '%s\tmine.txt\n' "$O" >> "$AGENT_BOARD_DIR/paths/$(cd "$O" && "$AB" mine | xargs basename | sed 's/\.md$//')"
want 'release with dirty files warns instead'      'still have uncommitted changes' "$(cd "$O" && "$AB" release)"
rm -f "$O/mine.txt"

echo
echo 'observed file sets — deploy'
PD=$(fake_named "$D" peer-deploy)
fake_writes "$PD" "$D" group_vars.yml
out=$(cd "$D" && "$AB" check)
want 'a peer is listed with the file it is sitting on' 'peer-deploy' "$out"
want 'and the file is named'                           'group_vars.yml' "$out"
want 'with no overlap, say so plainly'                 'no overlap' "$out"
printf 'and me\n' >> "$D/site.yml"
MYPID=$(cd "$D" && "$AB" mine | xargs basename | sed 's/\.md$//')
printf '%s\tsite.yml\n' "$D" >> "$AGENT_BOARD_DIR/paths/$MYPID"
want 'my own files are reported back to me'            'yours: site.yml' "$(cd "$D" && "$AB" check)"
wantnot 'different files are still no overlap'         'OVERLAP' "$(cd "$D" && "$AB" check)"
fake_writes "$PD" "$D" site.yml
out=$(cd "$D" && "$AB" check)
want 'the same file IS an overlap'                     'OVERLAP' "$out"
want 'named, with who to talk to'                      'peer-deploy: site.yml' "$out"
git -C "$D" add site.yml >/dev/null; git -C "$D" commit -qm 'landed'
wantnot 'committing releases both claims'              'OVERLAP' "$(cd "$D" && "$AB" check)"

# Reported by a peer session: `check` said "no overlap" while git showed five
# modified files, because the claim set was empty (its edits predated the hook).
# An empty claim set is not a clean tree, and check must not conclude from it.
# README.md deliberately: a file no fixture has ever claimed, so the only thing
# that knows it is dirty is git.
printf 'edited before any hook existed\n' >> "$D/README.md"
out=$(cd "$D" && "$AB" check)
want 'check surfaces dirty files no claim covers'  'NOT COVERED BY ANY CLAIM' "$out"
want 'and names them'                              'README.md' "$out"
wantnot 'and does not also claim there is no overlap' 'no overlap' "$out"
git -C "$D" checkout -q -- README.md
want 'once clean, the plain verdict is back'       'no overlap' "$(cd "$D" && "$AB" check)"

echo
echo 'paths — including work the board cannot attribute'
printf 'by hand\n' >> "$D/README.md"
out=$(cd "$D" && "$AB" paths)
want 'a dirty file nobody was seen to write is flagged' 'claimed by no live agent' "$out"
want 'and named'                                        'README.md' "$out"
git -C "$D" checkout -q -- README.md
mkdir -p "$D/roles/brand_new"; printf 'y\n' > "$D/roles/brand_new/main.yml"
printf '%s\troles/brand_new/main.yml\n' "$D" >> "$AGENT_BOARD_DIR/paths/$MYPID"
want 'a file in a brand-new untracked directory still counts' 'roles/brand_new/main.yml' "$(cd "$D" && "$AB" paths)"
rm -rf "$D/roles"

echo
echo 'editing — the declared form of the same claim, for agents without hooks'
printf 'codex was here\n' >> "$D/group_vars.yml"
printf 'loose\n' > "$T/loose.txt"
want 'declaring a path records it'   'group_vars.yml' "$(cd "$D" && "$AB" editing group_vars.yml)"
want 'and it reads back as mine'     'yours: group_vars.yml' "$(cd "$D" && "$AB" check)"
want 'a path that does not exist is refused' 'no such file' "$(cd "$D" && "$AB" editing nope.yml 2>&1)"
want 'a path outside any repo is refused'    'not inside a git repo' "$(cd "$T" && "$AB" editing "$T/loose.txt" 2>&1)"
# An unregistered agent must be told, not quietly believed: this is the one case
# Codex hits, since nothing observes its edits for it.
mv "$AGENT_BOARD_DIR/sessions/$MYPID.md" "$T/mine.bak"
out=$(cd "$D" && "$AB" editing group_vars.yml 2>&1)
mv "$T/mine.bak" "$AGENT_BOARD_DIR/sessions/$MYPID.md"
want 'an unregistered agent is told to claim first' 'cannot be attributed' "$out"
git -C "$D" checkout -q -- group_vars.yml
wantnot 'and the claim lapses on commit, same as an observed one' 'yours: group_vars.yml' "$(cd "$D" && "$AB" check)"

echo
echo 'vault lease'
want 'free to begin with'          'vault lease: free' "$("$AB" vault status)"
want 'taking it reports back'      'vault lease taken' "$(cd "$D" && "$AB" vault take vault.yml)"
want 'and shows as held'           'HELD'              "$("$AB" vault status)"
want 'check names the holder'      'LEASE HELD'        "$(cd "$D" && "$AB" check)"
want 'freeing it works'            'lease released'    "$("$AB" vault free)"
want 'freeing twice is not an error' 'already free'    "$("$AB" vault free)"
# A genuinely dead pid: our own child, killed and reaped, so `kill -0` cannot
# race us. (A pid from a subshell is not ours to `wait` for, which made an
# earlier version of this case depend on how fast a `sleep 0.01` exited.)
# `trap - EXIT` before the exec is not tidiness: a backgrounded child inherits
# this shell's EXIT trap, and if the kill lands before the fork has exec'd
# sleep, the dying child runs cleanup and rm -rf's the whole test tree out from
# under the suite. That race is won or lost on machine load, which is exactly
# the kind of failure nobody believes is real.
{ trap - EXIT; exec sleep 30; } </dev/null >/dev/null 2>&1 & DEAD=$!
kill "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null
mkdir -p "$AGENT_BOARD_DIR/locks/vault.lease"
printf 'pid: %s\nname: ghost\nfile: vault.yml\nsince: now\n' "$DEAD" > "$AGENT_BOARD_DIR/locks/vault.lease/owner"
want 'a lease whose owner has died is cleared on read' 'vault lease: free' "$("$AB" vault status)"
PD2=$(fake_named "$D" peer-vault)
mkdir -p "$AGENT_BOARD_DIR/locks/vault.lease"
printf 'pid: %s\nname: peer-vault\nfile: vault.yml\nsince: now\n' "$PD2" > "$AGENT_BOARD_DIR/locks/vault.lease/owner"
want 'someone else holding it refuses my take' 'vault lease is HELD' "$(cd "$D" && "$AB" vault take vault.yml 2>&1)"
want 'and refuses my release'                  'not yours to release' "$("$AB" vault free 2>&1)"
rm -rf "$AGENT_BOARD_DIR/locks/vault.lease"

echo
echo 'worktrees — reported, never removed'
git -C "$O" worktree add -q -b feat/live "$T/app-live" main 2>/dev/null
git -C "$O" worktree add -q -b feat/merged "$T/app-merged" main 2>/dev/null
git -C "$O" worktree add -q -b feat/open "$T/app-open" main 2>/dev/null
printf 'a\n' > "$T/app-merged/f.txt"
git -C "$T/app-merged" add f.txt; git -C "$T/app-merged" commit -qm f
git -C "$O" merge -q --no-ff -m merge feat/merged
printf 'b\n' > "$T/app-open/g.txt"
git -C "$T/app-open" add g.txt; git -C "$T/app-open" commit -qm g
PL=$(fake "$T/app-live" 'busy in its own tree')
out=$(cd "$O" && "$AB" worktrees)
want 'a merged, clean worktree is offered for removal' 'MERGED and clean' "$out"
want 'with the exact command'                          'git worktree remove' "$out"
want 'an unmerged branch is left alone'                'not merged into main' "$out"
want 'a worktree with an agent in it is left alone'    'an agent is working here' "$out"
wantnot 'the main checkout is never listed'            "  $O  " "$out"
# Only worktrees the agents took (siblings of the checkout) get a removal
# suggestion; ~/.othertool/..., .claude/worktrees/... and scratchpads belong to
# whatever tool created them and keep their own state.
mkdir -p "$T/elsewhere"
git -C "$O" worktree add -q -b feat/other "$T/elsewhere/tree" main 2>/dev/null
printf 'c\n' > "$T/elsewhere/tree/h.txt"
git -C "$T/elsewhere/tree" add h.txt; git -C "$T/elsewhere/tree" commit -qm h
git -C "$O" merge -q --no-ff -m merge2 feat/other
out=$(cd "$O" && "$AB" worktrees)
want 'a tree another tool owns is not offered for removal' 'another tool manages this one' "$out"
want 'but its merged state is still reported'              'its branch is merged' "$out"

echo
echo 'the SessionStart injection'
inject() {
  CWD="$1" python3 -c 'import json,os;print(json.dumps({"session_id":"s","cwd":os.environ["CWD"]}))' \
    | (cd "$1" && "$AB" hook-start) \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}
out=$(inject "$O")
want 'names agents in other repos'        'peer-deploy' "$out"
wantnot 'but not ones in this checkout'   'peer-app'   "$out"
want 'carries the verdict for this repo'  'app'  "$out"
want 'and what to run before changing it' 'agentboard hold' "$out"
wantnot 'no standing policy paragraph'    'Whole-tree operations are still blocked' "$out"
out=$(inject "$D")
want 'in deploy, claims are automatic'    'recorded as you edit' "$out"
n=$(printf '%s\n' "$out" | grep -c .)
# 13, raised from 12 for the identity line. Deliberately, once: the name is the one
# thing in here a session cannot derive, and what to do with it lives in CLAUDE.md,
# which is in context already. The cap is here to make the next increase a decision
# rather than a drift, so raise it the same way — with a reason, not to get green.
if [ "$n" -le 13 ]; then pass=$((pass+1)); printf '  ok    the whole injection is %s lines\n' "$n"
else fail=$((fail+1)); printf '  FAIL  injection grew to %s lines\n%s\n' "$n" "$out"; fi

echo
echo 'the log is written but not injected'
(cd "$D" && "$AB" note 'deployed 2.4.0 to prod, verified' >/dev/null)
want 'log reads it back'          'deployed 2.4.0' "$(cd "$D" && "$AB" log)"
wantnot 'list does not carry it'  'deployed 2.4.0' "$(cd "$D" && "$AB" list)"
wantnot 'check does not carry it' 'deployed 2.4.0' "$(cd "$D" && "$AB" check)"
want 'intent still works, deprecated' 'superseded' "$(cd "$D" && "$AB" intent 'WILL COMMIT' 2>&1)"
want 'and lands in the log'           'intent: WILL COMMIT' "$(cd "$D" && "$AB" log)"

echo
echo 'PostToolUse records what was written'
printf 'z\n' >> "$D/site.yml"
P="$D/site.yml" python3 -c 'import json,os;print(json.dumps({"tool_name":"Write","tool_input":{"file_path":os.environ["P"]}}))' \
  | (cd "$D" && "$AB" hook-posttool)
want 'an Edit/Write shows up as mine' 'site.yml' "$(cd "$D" && "$AB" paths)"
P="/etc/hosts" python3 -c 'import json,os;print(json.dumps({"tool_name":"Write","tool_input":{"file_path":os.environ["P"]}}))' \
  | (cd "$D" && "$AB" hook-posttool)
want 'a write outside any repo is ignored' 'site.yml' "$(cd "$D" && "$AB" paths)"

echo
echo 'names — every session is addressable, because a name is an address'
N1=$(fake "$D" 'unnamed one'); N2=$(fake "$D" 'unnamed two')
n1=$(sed -n 's/^name: //p' "$AGENT_BOARD_DIR/sessions/$N1.md")
n2=$(sed -n 's/^name: //p' "$AGENT_BOARD_DIR/sessions/$N2.md")
case "$n1" in
  ''|'-'|claude) fail=$((fail+1)); printf '  FAIL  an unnamed session is issued a name (got "%s")\n' "$n1" ;;
  *-*) pass=$((pass+1)); printf '  ok    an unnamed session is issued a name (%s)\n' "$n1" ;;
  *) fail=$((fail+1)); printf '  FAIL  issued name is adjective-noun (got "%s")\n' "$n1" ;;
esac
if [ "$n1" = "$n2" ]; then fail=$((fail+1)); printf '  FAIL  two sessions get different names (both %s)\n' "$n1"
else pass=$((pass+1)); printf '  ok    two sessions get different names\n'; fi
want 'an issued name is marked as issued' 'name_source: auto' "$(cat "$AGENT_BOARD_DIR/sessions/$N1.md")"
# The point of all this: it can be addressed.
want 'and the issued name is a working address' "$n1 (pid" "$("$AB" tell "$n1" 'ping' 2>&1)"

# A name I chose outranks one the board made up, and takes effect on the next
# heartbeat rather than waiting for a restart.
printf '{"name":"vault-rotation","nameSource":"user","status":"busy"}' > "$AGENT_BOARD_CC_SESSIONS/$N1.json"
"$AB" claim --pid "$N1" --agent claude --cwd "$D" >/dev/null
want '/rename overrides the issued name' 'name: vault-rotation' "$(cat "$AGENT_BOARD_DIR/sessions/$N1.md")"
want 'and is recorded as mine, not issued' 'name_source: user' "$(cat "$AGENT_BOARD_DIR/sessions/$N1.md")"
want 'the old issued name stops resolving' 'no live agent named' "$("$AB" tell "$n1" 'ping' 2>&1)"

echo
echo 'personality stays out of the context window'
banner=$(cd "$D" && "$AB" board 2>&1)
want 'board wears the masthead' '╔═╗' "$banner"
inj=$(printf '{"cwd":"%s","session_id":"s"}' "$D" | (cd "$D" && "$AB" hook-start) 2>/dev/null)
wantnot 'the SessionStart injection does not'  'ANSI' "$(printf '%s' "$inj" | grep -c $'\033' | sed 's/^0$/none/;s/^[1-9].*/ANSI/')"
wantnot 'nor any box-drawing art'              '\u2554' "$inj"
out=$("$AB" sweep)
want 'sweep answers a human who asked'  'board' "$out"

echo
echo 'dev environment leases'
want 'nothing is leased to begin with' 'no dev environment is leased' "$("$AB" env status)"
out=$(cd "$D" && "$AB" env take sandbox --for 'widgets overlay' 2>&1)
want 'taking a box says so'           'sandbox is yours' "$out"
want 'and says how to give it back'   'agentboard env free sandbox' "$out"
want 'status names the holder and the work' 'widgets overlay' "$("$AB" env status)"
want 'check reports my own lease back to me' 'you hold the dev env lease on sandbox' "$(cd "$D" && "$AB" check)"
want 'taking it twice is not an error' 'you already hold sandbox' "$(cd "$D" && "$AB" env take sandbox 2>&1)"

# A lease is per box: holding one says nothing about another.
"$AB" env take testbed --for 'unrelated' >/dev/null 2>&1
want 'a second box leases independently' 'testbed' "$("$AB" env status)"
want 'freeing one leaves the other'      'sandbox' "$("$AB" env free testbed; "$AB" env status)"
wantnot 'and the freed one is gone'      'testbed' "$("$AB" env status)"

# Names are used as path segments, so they are validated, not trusted.
want 'a traversing name is refused' 'not a usable environment name' "$("$AB" env take ../../etc 2>&1)"
want 'and nothing was created'      'no dev environment' "$("$AB" env free sandbox >/dev/null; "$AB" env status)"

# Someone else's lease: written by hand, because a real peer would be a separate
# long-lived process and the point is what happens to *this* session.
P_ENV=$(fake_named "$O" 'sandbox-tester')
mkdir -p "$AGENT_BOARD_DIR/locks/env/sandbox.lease"
printf 'pid: %s
name: sandbox-tester
for: widgets smoke test
since: now
' "$P_ENV" \
  > "$AGENT_BOARD_DIR/locks/env/sandbox.lease/owner"
want 'a peer holding a box blocks my take' 'sandbox is IN USE' "$(cd "$D" && "$AB" env take sandbox 2>&1)"
want 'and check tells me who has it'       'sandbox-tester' "$(cd "$D" && "$AB" check)"
want 'and what they are doing on it'       'widgets smoke test' "$(cd "$D" && "$AB" check)"
want 'their lease is not mine to release'  'not yours to release' "$("$AB" env free sandbox 2>&1)"
want 'unless I say I mean it'              'sandbox released' "$(AGENT_BOARD_OVERRIDE=1 "$AB" env free sandbox 2>&1)"

# The self-heal: a lease whose owner has gone is not a lease. This is the whole
# reason it is a pid-owned directory and not an flock — an flock would already
# have been released by the kernel, and a plain marker file never would be.
mkdir -p "$AGENT_BOARD_DIR/locks/env/sandbox.lease"
printf 'pid: 999999
name: long-gone
for: x
since: then
' \
  > "$AGENT_BOARD_DIR/locks/env/sandbox.lease/owner"
want 'a lease held by a dead pid is cleared' 'no dev environment is leased' "$("$AB" env status)"

echo
echo 'the board panels — a view that sits open says "free", check does not'
mkdir -p "$AGENT_BOARD_DIR/bin"; ln -sf "$(dirname "$AB")/deploylock" "$AGENT_BOARD_DIR/bin/deploylock"
b=$(cd "$D" && "$AB" board 2>&1)
want 'the locks panel has a heading'     'locks' "$b"
want 'and reports a free deploy lock'    'deploy   free' "$b"
want 'and a free vault lease'            'vault    free' "$b"
want 'the dev boxes panel has a heading' 'dev boxes' "$b"
want 'and says so when none are leased'  'none under test' "$b"
"$AB" env take sandbox --for 'panel check' >/dev/null 2>&1
b=$(cd "$D" && "$AB" board 2>&1)
want 'a leased box shows its holder'  'sandbox' "$b"
want 'and what they are doing on it'  'panel check' "$b"
# The panel is the board's job; check must not say it a second time underneath.
case $(printf '%s' "$b" | grep -c 'panel check') in
  1) pass=$((pass+1)); printf '  ok    and only once, not doubled by check\n' ;;
  *) fail=$((fail+1)); printf '  FAIL  the lease is reported twice in one board\n' ;;
esac
want 'but check on its own still reports it' 'you hold the dev env lease' "$(cd "$D" && "$AB" check)"
"$AB" env free sandbox >/dev/null 2>&1

# deploylock resolves its own lock dir from AGENT_BOARD_DIR, so finding it on PATH
# still reads the right board — that fallback is wanted. What must not happen is
# reporting "held" when the binary is missing entirely: "I could not ask" is the
# honest answer, and the worst of the three to get wrong.
rm -f "$AGENT_BOARD_DIR/bin/deploylock"
want 'PATH is a legitimate fallback' 'deploy   free' "$(cd "$D" && "$AB" board 2>&1)"
want 'a missing deploylock is not a held lock' 'deploylock not found' \
  "$(cd "$D" && PATH=/usr/bin:/bin "$AB" board 2>&1)"

echo
echo 'wins — the one thing here that is not about collisions'
want 'an empty day says so'     'no wins recorded' "$("$AB" wins)"
want 'logging one counts it'    'That is 1 today' "$("$AB" win 'TICKET-123 widgets ACL live on prod')"
want 'and the count accumulates' 'That is 2 today' "$("$AB" win 'the nightly export runs in batches now')"
want 'wins lists what was logged' 'widgets ACL live on prod' "$("$AB" wins)"
# The person, not the instance name: an instance name is /renamed when the work
# moves on, and a tally read back later would credit a session that no longer
# answers to it.
want 'credited to the person, not the instance' \
  "$("$AB" mine | xargs -I{} sed -n 's/^person: //p' {})" "$("$AB" wins)"
want 'and it lands in that session log too' 'win: the nightly export' "$("$AB" log)"

# A win is a celebration, not a form. Anything that would forge a second entry or
# break the field separator is flattened rather than refused.
"$AB" win "$(printf 'multi\tline\nwin')" >/dev/null
want 'a tab or newline cannot forge a second win' 'That is 4 today' "$("$AB" win 'fourth')"

b=$(cd "$D" && "$AB" board 2>&1)
want 'the board carries a wins panel'  'wins today' "$b"
want 'with the tally in it'            '4 today' "$b"

# Ordering: sort runs on the whole line, so a burst inside one minute would come
# back alphabetically if the timestamp stopped at the minute.
rm -f "$AGENT_BOARD_DIR/wins/"*
printf '%s\n' "09:00:02	zulu	second" "09:00:01	alpha	first" > "$AGENT_BOARD_DIR/wins/$(date +%F).9991"
want 'same-minute wins stay chronological' 'first' "$(printf '%s' "$("$AB" wins)" | sed -n '2p')"

# Five days kept; today and yesterday shown. An old day is not "stale state" to be
# swept on sight — it is the point of keeping a tally — so it survives until it is
# old. The days in between are kept for `wins --all` and stay off the board.
printf '10:00:00	someone	ancient\n'      > "$AGENT_BOARD_DIR/wins/2020-01-01.9992"
printf '10:00:00	someone	threedaysago\n' > "$AGENT_BOARD_DIR/wins/$(date -v-3d +%F).9993"
"$AB" sweep >/dev/null
wantnot 'sweep drops wins past the keep window' 'ancient' "$("$AB" wins --all)"
want    'but keeps the ones inside it'          'threedaysago' "$("$AB" wins --all)"
wantnot 'the board stops at yesterday'          'threedaysago' "$(cd "$D" && "$AB" board 2>&1)"

echo
echo 'people — a name that does not follow the work'
PP1=$(fake "$D" 'one'); PP2=$(fake "$D" 'two')
p1=$(sed -n 's/^person: //p' "$AGENT_BOARD_DIR/sessions/$PP1.md")
p2=$(sed -n 's/^person: //p' "$AGENT_BOARD_DIR/sessions/$PP2.md")
case "$p1" in
  [A-Z]*) pass=$((pass+1)); printf '  ok    every session is given a person (%s)\n' "$p1" ;;
  *) fail=$((fail+1)); printf '  FAIL  person should be a capitalised name (got "%s")\n' "$p1" ;;
esac
if [ "$p1" = "$p2" ]; then fail=$((fail+1)); printf '  FAIL  two live sessions share %s\n' "$p1"
else pass=$((pass+1)); printf '  ok    two live sessions get different people\n'; fi
want 'the board shows person and instance together' " · " "$(cd "$D" && "$AB" board 2>&1)"
want 'a person is an address'          "(pid $PP1)" "$("$AB" tell "$p1" 'ping' 2>&1)"
want 'and I can type it in lower case' "(pid $PP1)" "$("$AB" tell "$(printf '%s' "$p1" | tr '[:upper:]' '[:lower:]')" 'ping' 2>&1)"
want 'the echo names them canonically' "$p1" "$("$AB" tell "$p1" 'ping' 2>&1)"

# The instance name is what follows the work; the person must not move with it.
printf '{"name":"ticket-123-acl","nameSource":"user","status":"busy"}' > "$AGENT_BOARD_CC_SESSIONS/$PP1.json"
"$AB" claim --pid "$PP1" --agent claude --cwd "$D" >/dev/null
want 'a rename changes the instance name' 'name: ticket-123-acl' "$(cat "$AGENT_BOARD_DIR/sessions/$PP1.md")"
want 'and leaves the person alone'        "person: $p1" "$(cat "$AGENT_BOARD_DIR/sessions/$PP1.md")"
want 'both still reach the same session'  "(pid $PP1)" "$("$AB" tell ticket-123-acl 'ping' 2>&1)"

echo
echo 'wins are shown in full — the sentence is the content'
rm -f "$AGENT_BOARD_DIR/wins/"*
long='TICKET-123 widgets ACL live on prod, and the ARM role composition now matches what the module actually declares'
"$AB" win "$long" >/dev/null
b=$(cd "$D" && COLUMNS=76 "$AB" board 2>&1)
wantnot 'nothing is truncated with an ellipsis' '…' "$b"
want    'the tail of a long win survives'  'actually declares' "$b"
# Two in the same second would otherwise tie-break on the message text.
printf '%s\n' "09:00:00	Aa	zebra first" "09:00:00	Aa	apple second" \
  > "$AGENT_BOARD_DIR/wins/$(date +%F).9994"
want 'same-second wins keep their order' 'zebra first' "$(printf '%s' "$("$AB" wins)" | sed -n '2p')"

# Yesterday under today, because the morning after is when it gets read out.
printf '09:12:00\tFitzwilliam\tthe cutover landed\n' > "$AGENT_BOARD_DIR/wins/$(date -v-1d +%F).9995"
b=$(cd "$D" && "$AB" board 2>&1)
want 'yesterday gets its own section'   'yesterday ·' "$b"
want 'with yesterday in it'             'the cutover landed' "$b"
want 'and a count to read out'          '1 yesterday' "$b"
want 'today is still above it'          'wins today' "$b"
rm -f "$AGENT_BOARD_DIR/wins/$(date -v-1d +%F).9995"
wantnot 'an empty yesterday shows nothing' 'yesterday ·' "$(cd "$D" && "$AB" board 2>&1)"

echo
# What separates a win from a note is a judgement call, and `win --help` is where
# an agent is standing when it makes one — so the guidance has to be in there, not
# just a usage line restating the syntax it already typed.
echo 'win --help carries the judgement, not just the syntax'
h=$("$AB" win --help 2>/dev/null)
want 'it says how to write one'      'excitement' "$h"
want 'and what does not count'       'started work on X' "$h"
want 'it names where a win surfaces' 'standup' "$h"
want 'and how long one is kept'      'Kept 5 days' "$h"
want 'the short flag works too'      'usage: agentboard win' "$("$AB" win -h 2>/dev/null)"
want 'help credits the caller by person' \
  "$("$AB" mine | xargs -I{} sed -n 's/^person: //p' {})" "$h"
# Help is a read. Asking what a win is must not register a session as a side effect,
# or every `--help` on a fresh machine leaves a ghost agent on the board.
E=$(mktemp -d)
want 'no session, no person line'    '0' \
  "$(AGENT_BOARD_DIR="$E" "$AB" win --help | grep -c 'Credited to your person' || true)"
want 'and help registers nobody'     '0' "$(ls "$E/sessions" 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$E"
# The bare usage still has to point at it, or the help only helps whoever guessed.
want 'bare usage points at --help'   'win --help' "$("$AB" win 2>&1 || true)"

echo
# env and vault both guard a *cycle* rather than a command, which is the thing
# neither name conveys and the thing an agent gets wrong. That belongs in --help.
echo 'the two leases explain the cycle they protect'
h=$("$AB" env --help 2>/dev/null)
want 'env help states the unit'      'whole test cycle' "$h"
want 'and why a box cannot be shared' 'one database and one running app' "$h"
want 'and what happens to others'    'refused outright' "$h"
want 'and that nothing needs listing' 'no inventory' "$h"
h=$("$AB" vault --help 2>/dev/null)
want 'vault help names the cycle'    'decrypt' "$h"
want 'and that the loss is silent'   'silently' "$h"
want 'and that it is enforced'       'enforced' "$h"
want 'short flag works here too'     'usage: agentboard vault' "$("$AB" vault -h 2>/dev/null)"
# --help must not fall through to the status branch it sits in front of, and must
# not take the thing it is describing.
wantnot 'env --help is not env status'   'who is testing where
' "$("$AB" env --help 2>/dev/null | head -1)"
wantnot 'vault --help takes no lease'    'HELD' "$("$AB" vault status 2>&1)"
want    'and neither does env --help'    'no dev environment is leased' "$("$AB" env status 2>&1)"

echo
# The board lives in a pane of fixed height. Wins are the only panel that grows
# all day, and they sit below everything the board exists for — so unbudgeted they
# evict the collision information on exactly the busiest day.
echo 'the board fits the pane it is given'
rm -f "$AGENT_BOARD_DIR/wins/"*
i=0; while [ "$i" -lt 12 ]; do
  printf '09:%02d:00	Fitzwilliam	win number %s, long enough to wrap onto a second line when the pane is narrow
' "$i" "$i"
  i=$((i+1))
done > "$AGENT_BOARD_DIR/wins/$(date +%F).9996"
# Heights relative to the header, not absolute: by this point the suite has a
# crowd of fake agents live, and a header sized by how many are awake is exactly
# the thing a hardcoded pane height gets wrong.
# The floor: what the board renders when told it has no room at all. Everything
# above this is header the layout cannot give back, so every threshold below is
# measured from it rather than guessed at a pane size.
hd=$(cd "$D" && AB_LINES=1 COLUMNS=78 "$AB" board 2>&1 | wc -l | tr -d ' ')
for H in $((hd+2)) $((hd+10)) $((hd+25)) $((hd+60)); do
  L=$(cd "$D" && AB_LINES=$H COLUMNS=78 "$AB" board 2>&1 | wc -l | tr -d ' ')
  if [ "$L" -le "$((H-2))" ]; then pass=$((pass+1)); echo "  ok    a ${H}-row pane gets $L lines"
  else fail=$((fail+1)); echo "  FAIL  a ${H}-row pane got $L lines (header $hd)"; fi
done
b=$(cd "$D" && AB_LINES=$((hd+10)) COLUMNS=78 "$AB" board 2>&1)
# Trimmed from the top: the newest win is the one that changes what anybody does
# next, and the older ones are still whole in `agentboard wins`.
want    'the newest win survives the trim'  'win number 11' "$b"
wantnot 'the oldest does not'               'win number 0,' "$b"
want    'and it says how many are missing'  'earlier today' "$b"
# The bug this replaced: a notice saying wins were dropped, with no win under it.
if printf '%s' "$b" | grep -q 'earlier today' && ! printf '%s' "$b" | grep -q '✦'; then
  fail=$((fail+1)); echo "  FAIL  a trim notice with nothing under it"
else pass=$((pass+1)); echo "  ok    a trim notice always has a win under it"; fi
# Unbudgeted is unchanged — a plain `board` scrolls and should print the lot.
want 'an unbudgeted board keeps them all' 'win number 0,' "$(cd "$D" && COLUMNS=78 "$AB" board 2>&1)"

# Yesterday yields to today rather than competing for the room, which lands the
# right way round on its own: at standup today is empty, so yesterday is in full.
printf '09:12:00	Arabella	the cutover landed
' > "$AGENT_BOARD_DIR/wins/$(date -v-1d +%F).9997"
want 'a crowded pane collapses yesterday' 'agentboard wins yesterday' \
  "$(cd "$D" && AB_LINES=$((hd+10)) COLUMNS=78 "$AB" board 2>&1)"
rm -f "$AGENT_BOARD_DIR/wins/$(date +%F).9996"
# The same budget, with today empty — which is what standup actually looks like.
want 'an empty today shows it in full'    'the cutover landed' \
  "$(cd "$D" && AB_LINES=$((hd+25)) COLUMNS=78 "$AB" board 2>&1)"
want 'and the pointer line leads somewhere' 'the cutover landed' "$("$AB" wins yesterday)"
want 'which has a short form too'           'the cutover landed' "$("$AB" wins -y)"
# This listing stopped being a debugging aid the moment the pane started eliding:
# it is now what the day gets read out from, so it wraps like the board does.
printf '08:00:00\tCuthbert\t%s\n' "$(printf 'a win long enough that nobody could read it aloud from one line %s' 'and then some more words to be sure it wraps twice over')" \
  > "$AGENT_BOARD_DIR/wins/$(date -v-1d +%F).9998"
o=$(COLUMNS=78 "$AB" wins -y)
if [ "$(printf '%s\n' "$o" | wc -l | tr -d ' ')" -gt 3 ]; then
  pass=$((pass+1)); echo "  ok    a long win is wrapped, not one line"
else fail=$((fail+1)); echo "  FAIL  a long win came back on one line"; fi
# Measured on the ASCII columns: awk counts bytes, and a line of 78 columns
# holding an em-dash or a ✦ is more bytes than that without being too wide.
if [ "$(printf '%s\n' "$o" | sed 's/[^ -~]//g' | awk 'length>78' | wc -l | tr -d ' ')" = 0 ]; then
  pass=$((pass+1)); echo "  ok    and no line runs past the width"
else fail=$((fail+1)); echo "  FAIL  a line ran past the width"; fi
# "2026-09-16" is the wrong answer to "which day was that".
want 'the day is named, not just dated'  'yesterday)' "$o"
want 'with a weekday to place it'        "$(date -v-1d '+%a')" "$o"
want 'and a count for the standup'       '·' "$o"
want '--all labels its days too'         'yesterday)' "$("$AB" wins --all)"
rm -f "$AGENT_BOARD_DIR/wins/$(date -v-1d +%F).9998"

echo
# An agent cannot introduce itself by a name nobody told it, and the person is the
# one thing in the injection a session cannot work out for itself.
echo 'an agent is told who it is'
want 'whoami answers with both names' "$("$AB" mine | xargs -I{} sed -n 's/^person: //p' {})" "$("$AB" whoami)"
want 'and the session name with it'   "$("$AB" mine | xargs -I{} sed -n 's/^name: //p' {})" "$("$AB" whoami)"
h=$(printf '{"cwd":"%s"}' "$D" | "$AB" hook-start | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
want 'the session start says the name' "$("$AB" whoami)" "$h"
# The guidance itself stays in CLAUDE.md, which is in context anyway; spending
# injected lines to repeat it would be paying twice for the same sentence.
wantnot 'without repeating CLAUDE.md'  'Introduce yourself' "$h"
# It is worth its cost only if it is small: no roster, no verdict, still a name.
want 'it is one sentence, not a banner' '1' \
  "$(printf '%s' "$h" | head -1 | grep -c 'On the agent board you are')"
# Decoration yields before content does.
want    'a roomy pane keeps the logo' '╔═╗╔═╗╔═╗' "$(cd "$D" && AB_LINES=$((hd+60)) COLUMNS=78 "$AB" board 2>&1)"
wantnot 'a short one drops it'        '╔═╗╔═╗╔═╗' "$(cd "$D" && AB_LINES=$((hd-6)) COLUMNS=78 "$AB" board 2>&1)"
rm -f "$AGENT_BOARD_DIR/wins/"*

echo
echo 'name themes'
mine="$AGENT_BOARD_DIR/sessions/$MYPID.md"
person_now() { sed -n 's/^person: //p' "$mine"; }
in_pool() {   # in_pool <name> <theme-listing-word...>
  # The pools below are written across several lines for readability, and a newline
  # is not a space as far as a case pattern is concerned.
  local hay; hay=$(printf '%s' "$2" | tr -s '[:space:]' ' ')
  case " $hay " in *" $1 "*) printf 'yes' ;; *) printf "no ($1)" ;; esac
}
WODE="Fitzwilliam Bartholomew Hyacinth Cuthbert Marigold Percival Wilhelmina Bertram
Araminta Horatio Millicent Tarquin Ottoline Algernon Clementine Peregrine Dorothea
Barnaby Euphemia Lysander Honoria Cecily Reginald Augusta Silas Prudence Roderick
Winifred Ambrose Beatrix Cornelius Drusilla Eustace Georgiana Hugo Isolde Jasper
Lavinia Montague Nerissa Octavia Phineas Rosamund Sebastian Theodosia Valentine
Griselda Mortimer Perpetua Thaddeus Arabella Ignatius Philippa Crispin"
TOLK="Balin Dwalin Thorin Fili Kili Dori Nori Ori Oin Gloin Bifur Bofur Bombur
Bilbo Frodo Samwise Merry Pippin Gandalf Aragorn Boromir Faramir Legolas Gimli
Elrond Arwen Galadriel Celeborn Eowyn Eomer Theoden Denethor Beregond Radagast
Treebeard Quickbeam Goldberry Glorfindel Erestor Lindir Haldir Halbarad Bard Beorn
Thranduil Elladan Elrohir Ioreth Hamfast Barliman"
BUTL="Jeeves Jarvis Carson Alfred Lurch Niles Geoffrey Hobson Benson Belvedere
Cadbury Sebastian Bates Barrow Molesley Stevens Hudson Crichton Beach Nestor Bunter
Passepartout Wadsworth Higgins French Rochester Coleman Codsworth Cogsworth Lumiere
Smithers Riffraff Jennings Butler Pennyworth Friday Meadowes Brinkley Oakshott
Bingham Spratt Seppings Georges Emilio Kato Probert"
MCU="Tony Steve Natasha Clint Bruce Thor Loki Peter Wanda Vision Sam Bucky Stephen
Wong Scott Hope Carol Fury Hill Coulson Pepper Happy Rhodey Nebula Gamora Drax
Rocket Groot Mantis Yondu Okoye Shuri Ramonda Nakia Killmonger Hela Valkyrie
Heimdall Korg Quill Yelena Kamala Monica Riri Namor Sersi Ikaris Makkari Phastos
Kingo"
want 'the default is wodehouse'        'wodehouse' "$("$AB" theme | head -1)"
want 'and it is marked as the live one' '● wodehouse' "$("$AB" theme)"
want 'the others are offered'           '○ mcu'      "$("$AB" theme)"
want 'and the tolkien pack with them'   '○ tolkien'  "$("$AB" theme)"
want 'and the butlers pack'             '○ butlers'  "$("$AB" theme)"
# A pack is a pool and a register, and the register is the half that gets forgotten.
want 'every pack ships a register'      '5' "$("$AB" theme | grep -c '^    "')"
want 'the listing says what agents are told' 'agents are told' "$("$AB" theme)"
for v in WODEHOUSE TOLKIEN BUTLERS STARWARS MCU; do
  dup=$(sed -n "/^AB_PERSON_$v=\"/,/\"$/p" "$AB" \
        | sed "s/^AB_PERSON_$v=\"//; s/\"$//" \
        | tr -s '[:space:]' '\n' | grep . | sort | uniq -d | tr '\n' ' ')
  want "no duplicate names in $v" '' "$dup"
done
want 'a person starts in that pool'     'yes' "$(in_pool "$(person_now)" "$WODE")"
# A typo must not be able to half-apply, and must not stop anything registering.
want 'an unknown theme is refused'   'no such theme' "$("$AB" theme klingon 2>&1)"
want 'and nothing moves'             'wodehouse' "$("$AB" theme | head -1)"
printf 'klingon\n' > "$AGENT_BOARD_DIR/theme"
want 'garbage on disk reads as the default' 'wodehouse' "$("$AB" theme | head -1)"
want 'and a session still registers'        'yes' "$(in_pool "$(person_now)" "$WODE")"
rm -f "$AGENT_BOARD_DIR/theme"
# The switch does not write anyone's session file: each agent re-names itself on
# its own next hook event, which is what keeps the one-writer-per-file rule true.
before=$(person_now)
peer=$(fake_named "$O" themed-peer)
peerfile="$AGENT_BOARD_DIR/sessions/$peer.md"
peer_before=$(sed -n 's/^person: //p' "$peerfile")
want 'switching reports the move'    'wodehouse → mcu' "$("$AB" theme mcu 2>&1)"
want 'my own name moves at once'     'yes' "$(in_pool "$(person_now)" "$MCU")"
wantnot 'and it is not the old one'  "$before" "$(person_now)"
# The switching process must not reach into anyone else's file, so a session that
# was already live still carries its old name until it next writes for itself.
want 'a peer is untouched by my switch' "$peer_before" \
  "$(sed -n 's/^person: //p' "$peerfile")"
want 'and it was an old-theme name'     'yes' "$(in_pool "$peer_before" "$WODE")"
# Idempotence matters more than it looks: touch_updated runs on every hook event,
# so a name that is already in the pool must not be re-rolled on each one.
steady=$(person_now); "$AB" heartbeat; "$AB" heartbeat
want 'a name already in the pool is left alone' "$steady" "$(person_now)"
want 'switching back moves it back'  'yes' \
  "$("$AB" theme wodehouse >/dev/null; "$AB" heartbeat; in_pool "$(person_now)" "$WODE")"
want 'switching to the current theme is a no-op' 'already wodehouse' "$("$AB" theme wodehouse)"
# The register travels with the pack, into the one place agents actually read it.
"$AB" theme tolkien >/dev/null; "$AB" heartbeat
want 'a dwarf is named like one'   'yes' "$(in_pool "$(person_now)" "$TOLK")"
want 'and greets like one'         'at your service' "$("$AB" theme | sed -n '/agents are told/,$p')"
th=$(printf '{"cwd":"%s"}' "$D" | "$AB" hook-start \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
want 'the session start carries the register' 'at your service' "$th"
want 'on the same line as the name'          '1' \
  "$(printf '%s' "$th" | head -1 | grep -c 'you are.*at your service')"
"$AB" theme mcu >/dev/null; "$AB" heartbeat
tm=$(printf '{"cwd":"%s"}' "$D" | "$AB" hook-start \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
wantnot 'and it changes with the pack' 'at your service' "$tm"
want 'to the new one'                  'comms check' "$tm"
"$AB" theme wodehouse >/dev/null; "$AB" heartbeat
# help is a read, like every other --help here: asking must not register a session.
n_before=$(ls "$AGENT_BOARD_DIR/sessions" | wc -l | tr -d ' ')
want 'help explains what a switch does' 'renames every live agent' "$("$AB" theme --help)"
want 'and asking registers nobody' "$n_before" "$(ls "$AGENT_BOARD_DIR/sessions" | wc -l | tr -d ' ')"

# A local pack is the escape hatch from our taste in names, so it has to work
# without touching the shipped file: written to disk, selectable, and overriding a
# shipped pack of the same name.
L="$AGENT_BOARD_DIR/themes.local"
want 'a scaffold is written where it is read from' 'themes.local/pratchett.theme' \
  "$("$AB" theme --new pratchett)"
want 'and it is not selectable while empty' '[names] is missing' \
  "$("$AB" theme pratchett 2>&1)"
want 'but it is listed, so it can be fixed' 'pratchett' "$("$AB" theme)"
want 'the live theme is untouched by a broken pack' 'wodehouse' "$("$AB" theme | head -1)"
want 'and a second scaffold refuses to clobber the first' 'already exists' \
  "$("$AB" theme --new pratchett 2>&1)"
want 'a theme name is constrained'  'lowercase letters' "$("$AB" theme --new 'Bad Name' 2>&1)"
cat > "$L/pratchett.theme" <<'EOF'
[names]
Vimes Vetinari Nobby Colon Carrot Angua Detritus Cheery   # the Watch
Rincewind Ridcully Stibbons Granny Nanny Magrat Tiffany Susan
[greeting]
Greet with it and sign off with it, in the dry register of the Watch: "Vimes, reporting." to open, "Carrot, off duty." to close.
[art]
  ### # # ###   # a hash here is a pixel, not a comment
EOF
want 'a filled pack is offered'     '○ pratchett (local)' "$("$AB" theme)"
want 'with its own sample names'    'Vimes, Vetinari' "$("$AB" theme)"
want 'switching to it works'        'wodehouse → pratchett' "$("$AB" theme pratchett 2>&1)"
"$AB" heartbeat
want 'and names come from its pool' 'yes' \
  "$(in_pool "$(person_now)" 'Vimes Vetinari Nobby Colon Carrot Angua Detritus Cheery
Rincewind Ridcully Stibbons Granny Nanny Magrat Tiffany Susan')"
want 'a comment outside [art] is stripped' 'no (the)' \
  "$(in_pool the 'Vimes Vetinari Nobby Colon Carrot Angua Detritus Cheery
Rincewind Ridcully Stibbons Granny Nanny Magrat Tiffany Susan')"
lt=$(printf '{"cwd":"%s"}' "$D" | "$AB" hook-start \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
want 'its register reaches the session start' 'dry register of the Watch' "$lt"
# The banner is part of the pack, and a # inside [art] is a pixel rather than the
# start of a comment — which is the whole reason [art] is parsed differently.
want 'the art replaces the shipped banner' '### # # ###' "$("$AB" board)"
want 'and a hash in it survives'            'a hash here is a pixel' "$("$AB" board)"
wantnot 'the shipped banner is gone'        'AGENT' "$("$AB" board | head -2)"
# Overriding a shipped pack is the point of the mechanism, not an accident of it.
cp "$L/pratchett.theme" "$L/mcu.theme"
want 'a local pack overrides the shipped one' 'mcu (local, overriding' "$("$AB" theme)"
want 'and its names are the local ones'       'yes' \
  "$("$AB" theme mcu >/dev/null; "$AB" heartbeat; in_pool "$(person_now)" 'Vimes Vetinari
Nobby Colon Carrot Angua Detritus Cheery Rincewind Ridcully Stibbons Granny Nanny
Magrat Tiffany Susan')"
rm -f "$L/mcu.theme"
want 'removing it restores the shipped pack'  'yes' \
  "$("$AB" theme mcu >/dev/null 2>&1; "$AB" heartbeat; in_pool "$(person_now)" "$MCU")"
# An [art] section is not allowed to eat a short pane: board_head budgets against
# the pane height, and an unbounded banner would push live agents off it.
{ printf '[names]\nAda Grace Hedy\n[greeting]\nSay it plainly.\n[art]\n'
  i=0; while [ $i -lt 40 ]; do printf 'row%s\n' "$i"; i=$((i+1)); done; } > "$L/tall.theme"
"$AB" theme tall >/dev/null
want 'a runaway banner is capped'  '12' "$("$AB" board | grep -c '^row')"
"$AB" theme wodehouse >/dev/null; "$AB" heartbeat
# Local packs are read, never sourced. A file is not a script.
printf '[names]\n$(touch %s/PWNED) Ada\n[greeting]\nSay it plainly.\n' "$AGENT_BOARD_DIR" \
  > "$L/evil.theme"
"$AB" theme evil >/dev/null; "$AB" heartbeat; "$AB" theme >/dev/null
want 'a pack is data, not code' 'no' \
  "$([ -e "$AGENT_BOARD_DIR/PWNED" ] && echo yes || echo no)"
"$AB" theme wodehouse >/dev/null; "$AB" heartbeat

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

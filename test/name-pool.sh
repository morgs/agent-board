#!/bin/bash
# Verifies what happens when the person pool runs out, and what a session file
# that was never finished does to the session that owns it:
#   - a draw against a full pool is one scan of the board, not one per candidate
#   - a session with no person looks for a free one on a timer, not on every hook
#   - a claim killed part-way never leaves an empty session file
#   - an empty session file delivers nothing, and is put right at the next hook
#
# Self-contained: throwaway boards, a local theme pack, stand-in agents.
#
#   ~/agent-board/test/name-pool.sh
set -uo pipefail

AB=${AB:-$HOME/agent-board/bin/agentboard}
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentboard-pool.XXXXXX")" && pwd -P)
export AGENT_BOARD_DIR="$T/board"
export AGENT_BOARD_CC_SESSIONS="$T/cc"
mkdir -p "$AGENT_BOARD_DIR/sessions" "$AGENT_BOARD_DIR/themes.local" "$AGENT_BOARD_CC_SESSIONS"

FAKES=()
cleanup() { for p in ${FAKES+"${FAKES[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()  { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1 — no /$3/ in: $2"; fi; }
hasnt(){ if printf '%s' "$2" | grep -q -- "$3"; then bad "$1 — unexpected /$3/ in: $2"; else ok "$1"; fi; }

standin() {   # -> pid of a live process to hang a session on
  { trap - EXIT; exec sleep 3000; } </dev/null >/dev/null 2>&1 &
  local p=$!; disown "$p" 2>/dev/null; FAKES+=("$p"); printf '%s' "$p"
}
# Written by hand, not with `claim`: thirty claims are thirty draws, and the point
# of the first case is how long ONE draw takes once all of these exist.
session() {   # session <board> <pid> <person>
  local now; now=$(date +%s)
  cat > "$1/sessions/$2.md" <<EOF
agent: codex
name: s$2
name_source: user
person: $3
pid: $2
session: -
started: $(date +%Y-%m-%dT%H:%M:%S%z)
updated: $(date +%Y-%m-%dT%H:%M:%S%z)
epoch: $now
status: ACTIVE
cwd: $T
repo:
branch:
scope: -
hold: -
hold_since: -
state: -
inbox_epoch: $now

EOF
}
person_of() { sed -n 's/^person: //p' "$1" | head -1; }
broadcast() {   # broadcast <board> <from-pid> <age in seconds> <text>
  local e=$(( $(date +%s) - $3 ))
  cat > "$1/messages/$e.$2.$RANDOM.md" <<EOF
from_pid: $2
from_name: elder
from_agent: codex
to: *
epoch: $e
time: $(date +%Y-%m-%dT%H:%M:%S%z)

$4
EOF
}

# A pool the size of the one that ran out (31), and a board the size of the one it
# ran out on: 20 sessions here, the other names live on a peer, one name pinned.
POOL=""; for i in $(seq 1 31); do POOL="$POOL Crew-$i"; done
printf '[names]\n%s\n\n[greeting]\nSay "Crew-1, here." to open.\n' "$POOL" \
  > "$AGENT_BOARD_DIR/themes.local/crew.theme"
printf 'crew\n' > "$AGENT_BOARD_DIR/theme"
cat > "$AGENT_BOARD_DIR/machines.local" <<EOF
[local]
label = alpha

[peer]
label = beta

[relay]
stale = 600
EOF
mkdir -p "$AGENT_BOARD_DIR/remote/beta" "$AGENT_BOARD_DIR/messages"
date +%s > "$AGENT_BOARD_DIR/remote/beta/synced"
HELD=()
for i in $(seq 1 20); do
  p=$(standin); HELD+=("$p"); session "$AGENT_BOARD_DIR" "$p" "Crew-$i"
done
for i in $(seq 21 30); do
  printf '%s\tCrew-%s\tremote-%s\tclaude\tidle\t-\t-\t-\t0\n' "$((90000+i))" "$i" "$i"
done > "$AGENT_BOARD_DIR/remote/beta/sessions.tsv"
printf 'some-role = Crew-31\n' > "$AGENT_BOARD_DIR/persons.local"

echo 'a full pool'
"$AB" claim >/dev/null 2>&1
MINE=$("$AB" mine)
has 'this session registered'  "$MINE" '/sessions/'
NEW=$(standin)
s=$(date +%s)
"$AB" claim --pid "$NEW" --agent codex --cwd "$T" >/dev/null
took=$(( $(date +%s) - s ))
NEWF="$AGENT_BOARD_DIR/sessions/$NEW.md"
check 'a draw against a full pool gets the placeholder' "$(person_of "$NEWF")" 'Anon'
# One draw used to rescan the board for every candidate: 96 scans, 28 s measured,
# and the hook that ran it was killed at 10. The bound is loose on purpose.
if [ "$took" -le 5 ]; then ok "and takes one scan, not one per candidate (${took}s)"
else bad "a draw against a full pool took ${took}s"; fi
check 'the session file is whole all the same' "$(sed -n 's/^pid: //p' "$NEWF")" "$NEW"
check 'a pinned name is not handed out, though nobody holds it' \
  "$(grep -l '^person: Crew-31$' "$AGENT_BOARD_DIR"/sessions/*.md 2>/dev/null | wc -l | tr -d ' ')" '0'
check 'this session drew the placeholder too' "$(person_of "$MINE")" 'Anon'

echo
echo 'no person: look again on a timer'
"$AB" heartbeat
check 'still nothing free, still the placeholder' "$(person_of "$MINE")" 'Anon'
has   'and the look is recorded' "$(cat "$MINE")" '^person_tried: [0-9]'
# Crew-7 goes home.
kill "${HELD[6]}" 2>/dev/null; rm -f "$AGENT_BOARD_DIR/sessions/${HELD[6]}.md"
"$AB" heartbeat; "$AB" heartbeat
check 'a name is free, but the next hook does not look again yet' "$(person_of "$MINE")" 'Anon'
AGENT_BOARD_ANON_RETRY_SECS=0 "$AB" heartbeat
check 'once the timer is up, it takes the free name' "$(person_of "$MINE")" 'Crew-7'
steady=$(cat "$MINE" | grep -v '^updated:\|^epoch:')
AGENT_BOARD_ANON_RETRY_SECS=0 "$AB" heartbeat
check 'and a session with a person is left alone' \
  "$(cat "$MINE" | grep -v '^updated:\|^epoch:')" "$steady"
# Crew-12 goes home; a new session finds it wherever its own draw starts.
kill "${HELD[11]}" 2>/dev/null; rm -f "$AGENT_BOARD_DIR/sessions/${HELD[11]}.md"
NEW2=$(standin)
"$AB" claim --pid "$NEW2" --agent codex --cwd "$T" >/dev/null
check 'the one free name in the pool is found' \
  "$(person_of "$AGENT_BOARD_DIR/sessions/$NEW2.md")" 'Crew-12'

echo
echo 'a claim killed part-way'
# `date` is the last thing a claim asks for before it writes, so a slow one holds
# the claim exactly where the hook timeout used to catch it.
K="$T/board-killed"; mkdir -p "$K/sessions" "$T/slowbin"
REALDATE=$(command -v date)
printf '#!/bin/sh\nsleep 2\nexec %s "$@"\n' "$REALDATE" > "$T/slowbin/date"
chmod +x "$T/slowbin/date"
VICTIM=$(standin)
AGENT_BOARD_DIR="$K" PATH="$T/slowbin:$PATH" "$AB" claim --pid "$VICTIM" --agent codex --cwd "$T" \
  >/dev/null 2>&1 &
CL=$!
sleep 1; kill -9 "$CL" 2>/dev/null; wait "$CL" 2>/dev/null
VF="$K/sessions/$VICTIM.md"
check 'leaves no empty session file' \
  "$( { [ ! -e "$VF" ] || [ -s "$VF" ]; } && echo none || echo empty)" 'none'
sleep 2.2   # the orphaned `date` is done
AGENT_BOARD_DIR="$K" "$AB" claim --pid "$VICTIM" --agent codex --cwd "$T" >/dev/null
check 'and the next claim writes a whole one' "$(sed -n 's/^pid: //p' "$VF")" "$VICTIM"
has   'with a person' "$(person_of "$VF")" '^[A-Z]'
: > "$K/sessions/$VICTIM.md.tmp.999999"   # what a kill between write and move leaves
AGENT_BOARD_DIR="$K" "$AB" sweep >/dev/null 2>&1
check 'sweep collects a temp file whose writer is gone' \
  "$(ls "$K/sessions" | grep -c 'tmp')" '0'
check 'and leaves the session' "$([ -s "$VF" ] && echo kept || echo gone)" 'kept'

echo
echo 'an empty session file'
PEER=${HELD[0]}
broadcast "$AGENT_BOARD_DIR" "$PEER" 300 'old news from before you arrived'
check 'a broadcast older than the session is not for it' \
  "$("$AB" inbox 2>&1)" 'no new messages'
: > "$MINE"
out=$("$AB" inbox 2>&1)
hasnt 'with no pid, the inbox does not fall back to everything' "$out" 'old news'
check 'it says there is nothing' "$out" 'no new messages'
check 'and nothing is written into read/' "$(ls "$AGENT_BOARD_DIR/read" | wc -l | tr -d ' ')" '0'
check '`mine` does not offer the empty file' "$("$AB" mine 2>&1)" 'no session file'
who=$("$AB" whoami)
has   'the next command that needs a session writes a whole one' "$(cat "$MINE")" '^pid: [0-9]'
has   'and it has a person again' "$who" '[A-Za-z]'
hasnt 'the fresh claim starts its inbox now, not at zero' "$("$AB" inbox 2>&1)" 'old news'
printf 'agent: claude\nstatus: ACTIVE\n\n' > "$MINE"
check 'a file with fields but no pid is no session either' \
  "$("$AB" inbox 2>&1)" 'no new messages'
"$AB" whoami >/dev/null
has   'and is rewritten the same way' "$(cat "$MINE")" '^pid: [0-9]'

echo
echo 'the Stop hook heals, and does not loop'
# A stand-in claude, so the hook sees an agent above it, on a board of its own so
# no session file further up this test's process tree answers first.
S="$T/board-stop"; mkdir -p "$S/sessions" "$S/messages" "$T/fakebin"
ln -s /bin/bash "$T/fakebin/claude"   # a copy is killed by code signing
ELDER=$(standin); session "$S" "$ELDER" 'Elder'
broadcast "$S" "$ELDER" 300 'old news from before you arrived'
export -f broadcast
AGENT_BOARD_DIR="$S" "$T/fakebin/claude" -c "
  '$AB' claim >/dev/null
  f=\$('$AB' mine); printf '%s' \"\$f\" > '$T/stop-file'
  : > \"\$f\"
  printf '{}' | '$AB' hook-stop > '$T/stop-1' 2>&1
  cp \"\$f\" '$T/after-stop'
  printf '{}' | '$AB' hook-stop > '$T/stop-2' 2>&1
  broadcast '$S' $ELDER 0 'fresh news'
  printf '{}' | '$AB' hook-stop > '$T/stop-3' 2>&1
  printf '{}' | '$AB' hook-stop > '$T/stop-4' 2>&1
  : > \"\$f\"
  printf '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"true\"}}' | '$AB' hook-pretool > '$T/pretool' 2>&1
  cp \"\$f\" '$T/after-pretool'
  true" 2>/dev/null
has   'the stand-in session registered' "$(cat "$T/stop-file" 2>/dev/null)" '/sessions/'
check 'Stop on an empty file delivers nothing' "$(cat "$T/stop-1" 2>/dev/null)" ''
has   'and writes a whole session file over it' "$(cat "$T/after-stop" 2>/dev/null)" '^pid: [0-9]'
check 'the old broadcast does not come back at the next Stop' "$(cat "$T/stop-2" 2>/dev/null)" ''
has   'a message posted after that is delivered' "$(cat "$T/stop-3" 2>/dev/null)" 'fresh news'
hasnt 'without the old one' "$(cat "$T/stop-3" 2>/dev/null)" 'old news'
check 'and delivered once' "$(cat "$T/stop-4" 2>/dev/null)" ''
has   'a tool call puts an empty file right too' "$(cat "$T/after-pretool" 2>/dev/null)" '^pid: [0-9]'

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]

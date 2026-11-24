#!/bin/bash
# Verifies that a person stays its session's after the session stops looking live:
#   - inside the grace period no new session draws it, and after it one does
#   - when every free name is in grace, a new session takes the oldest, not Anon
#   - a session that comes back (same session id, same pane, same chosen name) has
#     its person again, and a pin still comes first
#   - a person in grace on a peer machine is held here too
#   - a Codex session hosted by the app-server daemon keeps its person when the
#     daemon restarts under a new pid, and records no pane
#   - a session marked DONE whose agent works again is ACTIVE again, as it was
#
# Self-contained: throwaway boards, a local theme pack, stand-in agents.
#
#   ~/agent-board/test/person-grace.sh
set -uo pipefail

AB=${AB:-$HOME/agent-board/bin/agentboard}
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentboard-grace.XXXXXX")" && pwd -P)
export AGENT_BOARD_CC_SESSIONS="$T/cc"
mkdir -p "$AGENT_BOARD_CC_SESSIONS"
# The run may itself sit in a pane: every stand-in would then be "the same pane".
unset HERDR_PANE_ID TMUX_PANE AGENT_BOARD_PERSON_GRACE_SECS

: > "$T/fakes"
cleanup() { while read -r p; do kill "$p" 2>/dev/null; done < "$T/fakes"; rm -rf "$T"; }
trap cleanup EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
differ(){ if [ "$2" != "$3" ] && [ -n "$2" ]; then ok "$1"; else bad "$1 (got [$2])"; fi; }
has()  { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1 — no /$3/ in: $2"; fi; }

# A live process to hang a session on. The pid comes back in SP, not on stdout: a
# $(...) would start it in a subshell, and it has to be recorded for the cleanup.
# The EXIT trap is off across the fork: a child killed before it reaches its exec
# would run the cleanup, and remove the boards under the test.
standin() {
  trap - EXIT
  { exec sleep 3000; } </dev/null >/dev/null 2>&1 &
  SP=$!
  trap cleanup EXIT
  disown "$SP" 2>/dev/null; printf '%s\n' "$SP" >> "$T/fakes"
}
# The draw starts at pool[(pid / 7) % size]. This one starts at the given person.
seeded() {   # seeded <person Crew-N> <pool size>
  local want=$(( ${1#Crew-} - 1 )) i=0
  while [ "$i" -lt 400 ]; do
    standin
    [ $(( SP / 7 % $2 )) -eq "$want" ] && return 0
    kill "$SP" 2>/dev/null; i=$((i+1))
  done
  return 1
}
gone() {   # gone <pid>: stop it, and wait until it is
  local i=0
  kill "$1" 2>/dev/null
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
}
board() {   # board <name> <pool size>: a new board with the names Crew-1..N
  local pool="" i
  export AGENT_BOARD_DIR="$T/$1"
  mkdir -p "$AGENT_BOARD_DIR/sessions" "$AGENT_BOARD_DIR/themes.local"
  for i in $(seq 1 "$2"); do pool="$pool Crew-$i"; done
  printf '[names]\n%s\n\n[greeting]\nSay "Crew-1, here." to open.\n' "$pool" \
    > "$AGENT_BOARD_DIR/themes.local/crew.theme"
  printf 'crew\n' > "$AGENT_BOARD_DIR/theme"
}
sfile()    { printf '%s/sessions/%s.md' "$AGENT_BOARD_DIR" "$1"; }
field()    { sed -n "s/^$2: //p" "$1" 2>/dev/null | head -1; }
person()   { field "$(sfile "$1")" person; }
claim()    { "$AB" claim --agent codex --cwd "$T" "$@" >/dev/null; }
ledger_n() { ls "$AGENT_BOARD_DIR/retired" 2>/dev/null | grep -c '\.md$' || true; }

echo 'inside the grace period'
board b1 6
standin; A=$SP
claim --pid "$A" --session sess-a
X=$(person "$A")
has   'a session draws a person'                          "$X" '^Crew-[1-6]$'
gone "$A"; "$AB" sweep >/dev/null 2>&1
check 'its process went, and sweep removed its file'      "$([ -e "$(sfile "$A")" ] && echo there || echo gone)" 'gone'
check 'the claim on its person moved to the ledger'       "$(ledger_n)" '1'
has   'with the person'      "$(cat "$AGENT_BOARD_DIR"/retired/*.md 2>/dev/null)" "^person: $X\$"
has   'and the session id'   "$(cat "$AGENT_BOARD_DIR"/retired/*.md 2>/dev/null)" '^session: sess-a$'
seeded "$X" 6; B=$SP
claim --pid "$B"
differ 'a new session whose draw starts at that person does not get it' "$(person "$B")" "$X"

echo
echo 'after the grace period'
old=$(( $(date +%s) - 86400 - 60 ))
for f in "$AGENT_BOARD_DIR"/retired/*.md; do
  sed "s/^epoch: .*/epoch: $old/" "$f" > "$f.new" && mv "$f.new" "$f"
done
seeded "$X" 6; C=$SP
claim --pid "$C"
check 'the person is drawn again'                          "$(person "$C")" "$X"
"$AB" sweep >/dev/null 2>&1
check 'and sweep drops the claim that ran out'             "$(ledger_n)" '0'
standin; D=$SP
claim --pid "$D"
Y=$(person "$D")
gone "$D"; AGENT_BOARD_PERSON_GRACE_SECS=0 "$AB" sweep >/dev/null 2>&1
check 'a grace period of 0 keeps no claim'                 "$(ledger_n)" '0'
seeded "$Y" 6; E=$SP
AGENT_BOARD_PERSON_GRACE_SECS=0 "$AB" claim --pid "$E" --agent codex --cwd "$T" >/dev/null
check 'and the person is free at once'                     "$(person "$E")" "$Y"
standin; F=$SP
claim --pid "$F"
Z=$(person "$F")
gone "$F"; "$AB" sweep >/dev/null 2>&1
seeded "$Z" 6; G=$SP
AGENT_BOARD_PERSON_GRACE_SECS=3600 "$AB" claim --pid "$G" --agent codex --cwd "$T" >/dev/null
differ 'the length is a setting: an hour holds it too'     "$(person "$G")" "$Z"

echo
echo 'a process that went, not swept yet'
board b2 6
standin; A=$SP
claim --pid "$A"
X=$(person "$A")
gone "$A"
seeded "$X" 6; B=$SP
claim --pid "$B"
differ 'its person is held before any sweep has run'       "$(person "$B")" "$X"

echo
echo 'every free name is in grace'
board b3 3
standin; L=$SP
claim --pid "$L"
standin; A=$SP
claim --pid "$A" --session sess-a
X=$(person "$A")
gone "$A"; "$AB" sweep >/dev/null 2>&1
standin; B=$SP
claim --pid "$B"
differ 'the one name outside grace goes first'             "$(person "$B")" "$X"
standin; C=$SP
claim --pid "$C"
check 'then a new session takes the name in grace, not the placeholder' "$(person "$C")" "$X"
standin; A2=$SP
claim --pid "$A2" --session sess-a
check 'its old session, back too late, gets what is left: nothing' "$(person "$A2")" 'Anon'

echo
echo 'a returning session'
board b4 10
standin; A=$SP
claim --pid "$A" --session sess-a
X=$(person "$A")
gone "$A"; "$AB" sweep >/dev/null 2>&1
standin; A2=$SP
claim --pid "$A2" --session sess-a
check 'the same session id under a new pid has its person again' "$(person "$A2")" "$X"
check 'and its ledger entry is used up'                    "$(ledger_n)" '0'

standin; B=$SP
HERDR_PANE_ID=w9:pA "$AB" claim --pid "$B" --agent codex --cwd "$T" >/dev/null
P2=$(person "$B")
check 'the pane is recorded'                               "$(field "$(sfile "$B")" pane)" 'w9:pA'
gone "$B"; "$AB" sweep >/dev/null 2>&1
seeded "$P2" 10; O=$SP
HERDR_PANE_ID=w9:pB "$AB" claim --pid "$O" --agent codex --cwd "$T" >/dev/null
differ 'a session in another pane does not get that person' "$(person "$O")" "$P2"
standin; B2=$SP
HERDR_PANE_ID=w9:pA "$AB" claim --pid "$B2" --agent codex --cwd "$T" >/dev/null
check 'a new session in the same pane does'                "$(person "$B2")" "$P2"

standin; C=$SP
claim --pid "$C" --name night-shift
P3=$(person "$C")
gone "$C"; "$AB" sweep >/dev/null 2>&1
standin; C2=$SP
claim --pid "$C2"
differ 'a session with no name yet draws another person'   "$(person "$C2")" "$P3"
err=$("$AB" claim --pid "$C2" --agent codex --cwd "$T" --name night-shift 2>&1 >/dev/null)
check 'when it takes the name it had, the person comes back' "$(person "$C2")" "$P3"
has   'and it is told so'                                  "$err" "$P3"

standin; D=$SP
claim --pid "$D"
P4=$(person "$D"); N4=$(field "$(sfile "$D")" name)
gone "$D"; "$AB" sweep >/dev/null 2>&1
standin; D2=$SP
claim --pid "$D2"
Q=$(person "$D2")
claim --pid "$D2" --name "$N4"
check 'a name the board issued is no claim on a person'    "$(person "$D2")" "$Q"

echo
echo 'pins'
board b7 10
printf 'keeper = Crew-10\n' > "$AGENT_BOARD_DIR/persons.local"
standin; K=$SP
claim --pid "$K" --name keeper
check 'a pinned session has its pin'                       "$(person "$K")" 'Crew-10'
gone "$K"; "$AB" sweep >/dev/null 2>&1
seeded Crew-10 10; O=$SP
claim --pid "$O"
differ 'nobody else draws the pin while it is away'        "$(person "$O")" 'Crew-10'
standin; K2=$SP
claim --pid "$K2" --name keeper
check 'and the pinned session has it back at once'         "$(person "$K2")" 'Crew-10'
standin; M=$SP
claim --pid "$M" --name mover
P5=$(person "$M")
gone "$M"; "$AB" sweep >/dev/null 2>&1
PIN=""
for i in 1 2 3 4 5 6 7 8 9; do   # a name nobody has, and not the one mover had
  [ "Crew-$i" = "$P5" ] && continue
  grep -q "^person: Crew-$i\$" "$AGENT_BOARD_DIR"/sessions/*.md 2>/dev/null && continue
  PIN="Crew-$i"; break
done
printf 'keeper = Crew-10\nmover = %s\n' "$PIN" > "$AGENT_BOARD_DIR/persons.local"
standin; M2=$SP
claim --pid "$M2" --name mover
check 'a pin comes before the person a returning session had' "$(person "$M2")" "$PIN"

echo
echo 'a person in grace on another machine'
board b8 3
printf '[local]\nlabel = here\n\n[peer]\nlabel = there\n' > "$AGENT_BOARD_DIR/machines.local"
mkdir -p "$AGENT_BOARD_DIR/remote/there"
date +%s > "$AGENT_BOARD_DIR/remote/there/synced"
now=$(date +%s)
printf 'Crew-1\t%s\nCrew-2\t%s\n' "$now" "$now" > "$AGENT_BOARD_DIR/remote/there/held.tsv"
standin; A=$SP
claim --pid "$A"
check 'a new session here draws the one name the peer does not hold' "$(person "$A")" 'Crew-3'
printf 'Crew-1\t%s\nCrew-2\t%s\n' "$(( now - 86400 - 60 ))" "$now" > "$AGENT_BOARD_DIR/remote/there/held.tsv"
standin; B=$SP
claim --pid "$B"
check 'and after the grace period, the name the peer held'  "$(person "$B")" 'Crew-1'
standin; C=$SP
claim --pid "$C"
gone "$C"; "$AB" sweep >/dev/null 2>&1
has   'this machine tells its peers which persons it holds' \
  "$("$AB" _export 2>/dev/null)" "^G	$(sed -n 's/^person: //p' "$AGENT_BOARD_DIR"/retired/*.md | head -1)	[0-9]"

echo
echo 'a Codex session on the app-server daemon'
board b5 6
daemon() {
  trap - EXIT
  { exec -a 'codex app-server --listen unix://x --managed-daemon' sleep 3000; } \
    </dev/null >/dev/null 2>&1 &
  SP=$!
  trap cleanup EXIT
  disown "$SP" 2>/dev/null; printf '%s\n' "$SP" >> "$T/fakes"
}
daemon; D1=$SP
sleep 0.2
has   'the stand-in looks like the daemon'  "$(ps -o args= -p "$D1")" 'app-server'
HERDR_PANE_ID=w1:pZ "$AB" claim --pid "$D1" --agent codex --cwd "$T" --session thread-1 >/dev/null
P=$(person "$D1")
check 'the daemon is not in the session pane: none is recorded' "$(field "$(sfile "$D1")" pane)" '-'
gone "$D1"; "$AB" sweep >/dev/null 2>&1
check 'the daemon restarted: the file under its old pid is gone' \
  "$([ -e "$(sfile "$D1")" ] && echo there || echo gone)" 'gone'
seeded "$P" 6; O=$SP
claim --pid "$O" --session thread-other
differ 'another session does not get the person meanwhile'  "$(person "$O")" "$P"
daemon; D2=$SP
sleep 0.2
HERDR_PANE_ID=w1:pQ "$AB" claim --pid "$D2" --agent codex --cwd "$T" --session thread-1 >/dev/null
check 'the session, under the new daemon pid, has its person' "$(person "$D2")" "$P"

echo
echo 'a session marked DONE that works again'
board b6 8
mkdir -p "$T/fakebin" "$T/out"
ln -s /bin/bash "$T/fakebin/codex"   # a copy is killed by code signing
export -f standin seeded gone sfile field person
cat > "$T/agent.sh" <<'EOS'
pl() {   # pl <event> <session id> [<command>]
  EV=$1 SID=$2 CMD=${3:-} CWD=$T python3 -c '
import json, os
d = {"session_id": os.environ["SID"], "transcript_path": None, "cwd": os.environ["CWD"],
     "hook_event_name": os.environ["EV"], "model": "gpt-test", "permission_mode": "default",
     "turn_id": "t1", "reason": "other"}
if os.environ["CMD"]:
    d.update(tool_name="Bash", tool_use_id="u1", tool_input={"command": os.environ["CMD"]})
print(json.dumps(d))'
}
st() { sed -n 's/^status: //p' "$f" | head -1; }
put() { printf '%s' "$2" > "$T/out/$1"; }
cd "$T"
pl SessionStart thread-9 | "$AB" hook-start --codex >/dev/null 2>&1
"$AB" claim --name builder --scope 'first task' >/dev/null 2>&1
f=$("$AB" mine); put file "$f"
p0=$(sed -n 's/^person: //p' "$f" | head -1); put p0 "$p0"
started=$(sed -n 's/^started: //p' "$f" | head -1)

"$AB" done; put done "$(st)"
pl PostToolUse thread-9 'agentboard done' | "$AB" hook-posttool --codex >/dev/null 2>&1
put after-posttool "$(st)"
pl Stop thread-9 | "$AB" hook-stop --codex >/dev/null 2>&1
put after-stop "$(st)"
pl PreToolUse thread-9 'agentboard release' | "$AB" hook-pretool --codex >/dev/null 2>&1
put after-release "$(st)"
"$AB" note 'a note at the end' >/dev/null 2>&1
put after-note "$(st)"

# A DONE file past its keep time: kept while its agent runs, dropped otherwise.
standin; plain=$SP
"$AB" claim --pid "$plain" --agent codex --cwd "$T" >/dev/null
sed 's/^status: .*/status: DONE/' "$(sfile "$plain")" > "$T/out/tmp" && mv "$T/out/tmp" "$(sfile "$plain")"
sleep 1.2
AGENT_BOARD_DONE_KEEP_SECS=0 "$AB" sweep >/dev/null 2>&1
put kept "$([ -e "$f" ] && echo kept || echo gone)"
put plain "$([ -e "$(sfile "$plain")" ] && echo kept || echo gone)"
seeded "$p0" 8; other=$SP
"$AB" claim --pid "$other" --agent codex --cwd "$T" >/dev/null
put other "$(person "$other")"
put listed-done "$("$AB" list --include-self 2>&1)"

pl PreToolUse thread-9 'true' | "$AB" hook-pretool --codex >/dev/null 2>&1
put after-pretool "$(st)"
put p1 "$(sed -n 's/^person: //p' "$f" | head -1)"
put scope1 "$(sed -n 's/^scope: //p' "$f" | head -1)"
put name1 "$(sed -n 's/^name: //p' "$f" | head -1)"
put started1 "$([ "$(sed -n 's/^started: //p' "$f" | head -1)" = "$started" ] && echo same || echo new)"
put listed-live "$("$AB" list --include-self 2>&1)"

"$AB" done
"$AB" scope 'second task' >/dev/null 2>&1
put after-scope "$(st)"

"$AB" done
pl SessionStart thread-9 | "$AB" hook-start --codex >/dev/null 2>&1
put after-start-same "$(st)"; put scope2 "$(sed -n 's/^scope: //p' "$f" | head -1)"

"$AB" done
pl SessionStart thread-10 | "$AB" hook-start --codex >/dev/null 2>&1
put after-start-other "$(st)"
put scope3 "$(sed -n 's/^scope: //p' "$f" | head -1)"
put p3 "$(sed -n 's/^person: //p' "$f" | head -1)"
put sid3 "$(sed -n 's/^session: //p' "$f" | head -1)"

pl SessionEnd thread-9 | "$AB" hook-end --codex >/dev/null 2>&1
put end-other "$(st)"
s=$(date +%s%N)
pl SessionEnd thread-10 | "$AB" hook-end --codex >/dev/null 2>&1
put end-ms "$(( ($(date +%s%N) - s) / 1000000 ))"
put end-own "$(st)"
EOS
AB="$AB" T="$T" "$T/fakebin/codex" "$T/agent.sh" 2>"$T/out/stderr"
o() { cat "$T/out/$1" 2>/dev/null; }
P0=$(o p0)
has   'the stand-in Codex session registered'              "$(o file)" '/sessions/'
check '`done` marks it DONE'                               "$(o done)" 'DONE'
check 'the PostToolUse of that call leaves it DONE'        "$(o after-posttool)" 'DONE'
check 'so does the Stop'                                   "$(o after-stop)" 'DONE'
check 'and a `release` after it'                           "$(o after-release)" 'DONE'
check 'and a note'                                         "$(o after-note)" 'DONE'
check 'past its keep time the file stays while the agent runs' "$(o kept)" 'kept'
check 'a DONE file of a process that is no agent is still dropped' "$(o plain)" 'gone'
differ 'its person is not drawn while it is DONE'          "$(o other)" "$P0"
if printf '%s' "$(o listed-done)" | grep -q 'builder'; then bad 'a DONE session is on the list'
else ok 'a DONE session is not on the list'; fi
check 'the next tool call makes it ACTIVE'                 "$(o after-pretool)" 'ACTIVE'
check 'with the same person'                               "$(o p1)" "$P0"
check 'the same scope'                                     "$(o scope1)" 'first task'
check 'the same name'                                      "$(o name1)" 'builder'
check 'in the same file, not a new one'                    "$(o started1)" 'same'
has   'and it is on the list again'                        "$(o listed-live)" 'builder'
check '`scope` after `done` makes it ACTIVE too'           "$(o after-scope)" 'ACTIVE'
check 'the same session starting again carries on'         "$(o after-start-same)" 'ACTIVE'
check 'with its scope'                                     "$(o scope2)" 'second task'
check 'another session on the same process gets a new file' "$(o scope3)" '-'
check 'which is ACTIVE'                                    "$(o after-start-other)" 'ACTIVE'
check 'with the person the process had'                    "$(o p3)" "$P0"
check 'and the new session id'                             "$(o sid3)" 'thread-10'
check 'the end of some other session on the process leaves it ACTIVE' "$(o end-other)" 'ACTIVE'
check 'its own end marks it DONE'                          "$(o end-own)" 'DONE'
ms=$(o end-ms)
if [ "${ms:-9999}" -lt 1000 ]; then ok "inside the second Codex gives SessionEnd (${ms}ms)"
else bad "hook-end --codex took ${ms}ms"; fi

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]

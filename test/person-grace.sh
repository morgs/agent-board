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
#   - claims that start together get different persons (the board lock)
#   - a file under a pid that another process had gives its person to nobody new
#   - a person that came back by session id is not replaced by a later name match
#   - two peers are two peers: the persons both hold stay out of the draw
#   - a claim or a sweep that cannot write loses no claim, and says that it failed
#   - a Codex SessionEnd and a claim take the same lock; only a shell call that runs
#     a sign-off leaves a DONE session DONE; a hook that finds no file makes one
#     with the thread's session id
#   - without the board lock nothing is written: a claim exits 75, a DONE session
#     stays DONE, no person is drawn again, and a heartbeat that waits in its
#     rename holds a claim back
#   - a session end that cannot have the lock is written down and applied later,
#     to the session it was the end of
#   - a claim that cannot save the person of the process before it changes nothing
#   - a tool hook does not take over the file of another process or another
#     session; a sign-off is found as the shell reads the command
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
echo 'claims that start together'
board b9 4
for i in 1 2 3 4; do standin; claim --pid "$SP" --session "old-$i"; eval "O$i=$SP"; done
for i in 1 2 3 4; do eval "gone \$O$i"; done
"$AB" sweep >/dev/null 2>&1
check 'all four names are in grace'                        "$(ledger_n)" '4'
N=""
for i in 1 2 3 4; do standin; N="$N $SP"; done
for p in $N; do claim --pid "$p" --session "new-$p" & done
wait
got=$(for p in $N; do person "$p"; done | sort)
check 'four claims at once: four different persons'        "$(printf '%s\n' "$got" | sort -u | grep -c .)" '4'
if printf '%s\n' "$got" | grep -q 'Anon'; then bad 'one of them got the placeholder'
else ok 'and none is the placeholder'; fi

echo
echo 'a pid that the system gave to another process'
board b10 6
ledger_has() { grep -lx "person: $1" "$AGENT_BOARD_DIR"/retired/*.md 2>/dev/null | grep -c . || true; }
refile() {   # refile <pid> <sed script>: change the session file as the test needs
  sed "$2" "$(sfile "$1")" > "$T/refile.tmp" && mv "$T/refile.tmp" "$(sfile "$1")"
}
standin; A=$SP
claim --pid "$A" --session s-a --name alpha --scope 'the old work'
PA=$(person "$A")
case "$(field "$(sfile "$A")" pstart)" in ''|'-') bad 'the file records when its process started' ;;
  *) ok 'the file records when its process started' ;; esac
refile "$A" 's/^status: .*/status: DONE/; s/^pstart: .*/pstart: another-start/'
claim --pid "$A" --session s-b --name beta
differ 'a DONE file of another process: its person is not passed on' "$(person "$A")" "$PA"
check 'that person stays claimed for its own session'      "$(ledger_has "$PA")" '1'
check 'the new session has a file of its own'              "$(field "$(sfile "$A")" session)" 's-b'
check 'without the old scope'                              "$(field "$(sfile "$A")" scope)" '-'

standin; B=$SP
claim --pid "$B" --session s-c --name gamma
PB=$(person "$B")
refile "$B" 's/^status: .*/status: DONE/; /^pstart: /d'
claim --pid "$B" --session s-d --name delta
differ 'a DONE file that does not say which process: no proof, not passed on' "$(person "$B")" "$PB"
check 'and its person stays claimed too'                   "$(ledger_has "$PB")" '1'

standin; C=$SP
claim --pid "$C" --session s-e --name epsilon --scope 'stale work'
PC=$(person "$C")
refile "$C" 's/^pstart: .*/pstart: another-start/'
claim --pid "$C" --session s-f --name zeta
differ 'an ACTIVE file of another process is not this session'"'"'s either' "$(person "$C")" "$PC"
check 'its person goes to the ledger'                      "$(ledger_has "$PC")" '1'
check 'and its scope is not taken over'                    "$(field "$(sfile "$C")" scope)" '-'
check 'nor its name'                                       "$(field "$(sfile "$C")" name)" 'zeta'

standin; D=$SP
claim --pid "$D" --session s-g --name eta
PD=$(person "$D")
refile "$D" 's/^status: .*/status: DONE/'
claim --pid "$D" --session s-h --name theta
check 'the same process with a new session keeps its person' "$(person "$D")" "$PD"

echo
echo 'a person restored by session id, then a name'
board b11 6
standin; A=$SP
claim --pid "$A" --session s-a --name alpha
PA=$(person "$A")
standin; B=$SP
claim --pid "$B" --session s-b --name bravo
PB=$(person "$B")
gone "$A"; gone "$B"; "$AB" sweep >/dev/null 2>&1
standin; N=$SP
claim --pid "$N" --session s-a
check 'the session is back with its person'                "$(person "$N")" "$PA"
check 'marked as its own, not drawn'                       "$(field "$(sfile "$N")" person_source)" 'back'
claim --pid "$N" --name bravo 2>/dev/null
check 'a name another session used does not change it'     "$(person "$N")" "$PA"
check 'and that session'"'"'s claim stays in the ledger'   "$(ledger_has "$PB")" '1'
standin; M=$SP
claim --pid "$M"
check 'a new session has a drawn person'                   "$(field "$(sfile "$M")" person_source)" 'drawn'
claim --pid "$M" --name bravo 2>/dev/null
check 'a drawn person does give way to the name'           "$(person "$M")" "$PB"
check 'and the claim is used'                              "$(ledger_has "$PB")" '0'

echo
echo 'persons in grace on two other machines'
board b12 4
printf '[local]\nlabel = here\n\n[peer]\nlabel = first\n\n[peer]\nlabel = second\n' \
  > "$AGENT_BOARD_DIR/machines.local"
now=$(date +%s)
for l in first second; do
  mkdir -p "$AGENT_BOARD_DIR/remote/$l"; printf '%s\n' "$now" > "$AGENT_BOARD_DIR/remote/$l/synced"
done
printf 'Crew-1\t%s\n' "$now" > "$AGENT_BOARD_DIR/remote/first/held.tsv"
printf 'Crew-2\t%s\n' "$now" > "$AGENT_BOARD_DIR/remote/second/held.tsv"
seeded Crew-1 4; A=$SP
claim --pid "$A"
check 'a draw that starts at the first peer'"'"'s person passes both' "$(person "$A")" 'Crew-3'
seeded Crew-2 4; B=$SP
claim --pid "$B"
check 'and one that starts at the second peer'"'"'s takes the last free name' "$(person "$B")" 'Crew-4'

echo
echo 'a session file that cannot be written'
board b13 4
standin; A=$SP
claim --pid "$A" --session s-a
PA=$(person "$A")
gone "$A"; "$AB" sweep >/dev/null 2>&1
check 'its claim is in the ledger'                         "$(ledger_n)" '1'
standin; N=$SP
chmod 555 "$AGENT_BOARD_DIR/sessions"
if [ -w "$AGENT_BOARD_DIR/sessions" ]; then
  chmod 755 "$AGENT_BOARD_DIR/sessions"
  ok 'skipped: this user writes to a read-only directory'
else
  "$AB" claim --agent codex --cwd "$T" --pid "$N" --session s-a >/dev/null 2>&1; rc=$?
  chmod 755 "$AGENT_BOARD_DIR/sessions"
  check 'the claim fails'                                  "$rc" '1'
  check 'no file was written'  "$([ -e "$(sfile "$N")" ] && echo there || echo none)" 'none'
  check 'the claim is still in the ledger'                 "$(ledger_n)" '1'
  claim --pid "$N" --session s-a
  check 'so the next claim has the person'                 "$(person "$N")" "$PA"
  check 'and only then is the ledger entry used'           "$(ledger_n)" '0'
fi

echo
echo 'a ledger that cannot be written'
board b14 4
standin; A=$SP
claim --pid "$A" --session s-a
PA=$(person "$A")
gone "$A"
rmdir "$AGENT_BOARD_DIR/retired" 2>/dev/null; : > "$AGENT_BOARD_DIR/retired"
"$AB" sweep >"$T/sweep.out" 2>&1; rc=$?
if [ "$rc" != 0 ]; then ok 'the sweep says it failed'; else bad 'the sweep exited 0'; fi
has   'and why'                                            "$(cat "$T/sweep.out")" 'could not save the person'
check 'the session file stays, with the person'            "$(person "$A")" "$PA"
rm -f "$AGENT_BOARD_DIR/retired"
"$AB" sweep >/dev/null 2>&1; rc=$?
check 'with the ledger back, the next sweep works'         "$rc" '0'
check 'the file is gone'      "$([ -e "$(sfile "$A")" ] && echo there || echo gone)" 'gone'
check 'and the claim is in the ledger'                     "$(ledger_has "$PA")" '1'
standin; N=$SP
claim --pid "$N" --session s-a
check 'so the session still gets its person back'          "$(person "$N")" "$PA"

echo
echo 'hooks of a Codex session: the board lock, sign-off calls, a lost file'
board b15 8
rm -rf "$T/out"; mkdir -p "$T/out"
cat > "$T/hold-lock.py" <<'EOS'
import fcntl, os, sys, time
f = open(sys.argv[1], "a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
while os.path.exists(sys.argv[2]):
    time.sleep(0.05)
EOS
cat > "$T/agent2.sh" <<'EOS'
pl() {   # pl <event> <session id> [<command> | <tool name> <tool input as JSON>]
  EV=$1 SID=$2 A=${3:-} B=${4:-} CWD=$T python3 -c '
import json, os
e = os.environ
d = {"session_id": e["SID"], "transcript_path": None, "cwd": e["CWD"],
     "hook_event_name": e["EV"], "model": "gpt-test", "permission_mode": "default",
     "turn_id": "t1", "reason": "other"}
if e["B"]:
    d.update(tool_name=e["A"], tool_use_id="u1", tool_input=json.loads(e["B"]))
elif e["A"]:
    d.update(tool_name="Bash", tool_use_id="u1", tool_input={"command": e["A"]})
print(json.dumps(d))'
}
st() { sed -n 's/^status: //p' "$f" | head -1; }
sid() { sed -n 's/^session: //p' "$f" | head -1; }
put() { printf '%s' "$2" > "$T/out/$1"; }
pre() { "$AB" done; pl PreToolUse thread-1 "$@" | "$AB" hook-pretool --codex >/dev/null 2>&1; st; }
cd "$T"
pl SessionStart thread-1 | "$AB" hook-start --codex >/dev/null 2>&1
f=$("$AB" mine); put file "$f"
put p0 "$(sed -n 's/^person: //p' "$f" | head -1)"

# A tool call on a DONE session: only a shell call that runs a sign-off leaves it DONE.
put read-named   "$(pre Read '{"file_path": "/x/notes on agentboard done.md"}')"
put bash-done    "$(pre 'agentboard done')"
put bash-path    "$(pre 'cd /x && ~/agent-board/bin/agentboard release')"
put bash-env     "$(pre 'AGENT_BOARD_OVERRIDE=1 agentboard env free aspen')"
put bash-quoted  "$(pre 'git commit -m "agentboard done" -- README.md')"
put bash-grep    "$(pre "grep -n 'agentboard release' README.md")"
put bash-other   "$(pre 'agentboard doneish')"
pl SessionStart thread-1 | "$AB" hook-start --codex >/dev/null 2>&1

# Someone else has the board lock.
lock="$AGENT_BOARD_DIR/locks/board.flock"
python3 "$T/hold-lock.py" "$lock" "$T/held" &
holder=$!
i=0; while [ ! -e "$T/held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
s=$(date +%s%N)
pl SessionEnd thread-1 | "$AB" hook-end --codex >/dev/null 2>&1
put locked-end-ms "$(( ($(date +%s%N) - s) / 1000000 ))"
put locked-end "$(st)"
"$AB" claim --session thread-2 >/dev/null 2>&1 &
claimer=$!
sleep 0.7
put locked-claim "$(sid)"
rm -f "$T/held"; wait "$holder" "$claimer"
put unlocked-claim "$(sid)"
pl SessionEnd thread-1 | "$AB" hook-end --codex >/dev/null 2>&1
put end-old "$(st)"
pl SessionEnd thread-2 | "$AB" hook-end --codex >/dev/null 2>&1
put end-own "$(st)"
EOS
AB="$AB" T="$T" "$T/fakebin/codex" "$T/agent2.sh" 2>"$T/out/stderr"
P0=$(o p0)
has   'the stand-in Codex session registered'              "$(o file)" '/sessions/'
check 'a Read of a file named after a sign-off makes it ACTIVE' "$(o read-named)" 'ACTIVE'
check '`agentboard done` in a shell leaves it DONE'        "$(o bash-done)" 'DONE'
check 'so does a `release` by path, after a `cd`'          "$(o bash-path)" 'DONE'
check 'and an `env free` behind a variable'                "$(o bash-env)" 'DONE'
check 'a sign-off inside quotes is not a sign-off'         "$(o bash-quoted)" 'ACTIVE'
check 'nor one that a grep looks for'                      "$(o bash-grep)" 'ACTIVE'
check 'nor a word that only starts like one'               "$(o bash-other)" 'ACTIVE'
check 'with the board lock held, SessionEnd does not sign off' "$(o locked-end)" 'ACTIVE'
ms=$(o locked-end-ms)
if [ "${ms:-9999}" -lt 1000 ]; then ok "and it is still inside its second (${ms}ms)"
else bad "hook-end --codex took ${ms}ms with the lock held"; fi
check 'a claim waits for the lock: the file is not changed' "$(o locked-claim)" 'thread-1'
check 'and writes when it has it'                          "$(o unlocked-claim)" 'thread-2'
check 'the end of the thread that had the file before leaves it ACTIVE' "$(o end-old)" 'ACTIVE'
check 'the end of the thread that has it marks it DONE'    "$(o end-own)" 'DONE'

# The process of the thread that had the file last (thread-2) is gone: a daemon
# restart. Its first hook under the new pid finds no file, and makes one: with the
# thread's id, so with its person.
cat > "$T/agent3.sh" <<'EOS'
EV=$1
cd "$T"
f="$AGENT_BOARD_DIR/sessions/$$.md"
SID=thread-2 EV=$EV CWD=$T python3 -c '
import json, os
e = os.environ
d = {"session_id": e["SID"], "transcript_path": None, "cwd": e["CWD"],
     "hook_event_name": e["EV"], "model": "gpt-test", "permission_mode": "default", "turn_id": "t1"}
if e["EV"] != "Stop":
    d.update(tool_name="Bash", tool_use_id="u1", tool_input={"command": "true"})
print(json.dumps(d))' > "$T/out/payload"
case "$EV" in
  PreToolUse)  "$AB" hook-pretool  --codex < "$T/out/payload" >/dev/null 2>&1 ;;
  PostToolUse) "$AB" hook-posttool --codex < "$T/out/payload" >/dev/null 2>&1 ;;
  Stop)        "$AB" hook-stop     --codex < "$T/out/payload" >/dev/null 2>&1 ;;
esac
f=$("$AB" mine 2>/dev/null)
printf '%s' "$(sed -n 's/^person: //p' "$f" 2>/dev/null | head -1)" > "$T/out/lost-person-$EV"
printf '%s' "$(sed -n 's/^session: //p' "$f" 2>/dev/null | head -1)" > "$T/out/lost-session-$EV"
EOS
for ev in PreToolUse PostToolUse Stop; do
  "$AB" sweep >/dev/null 2>&1
  AB="$AB" T="$T" "$T/fakebin/codex" "$T/agent3.sh" "$ev" 2>>"$T/out/stderr"
  check "$ev with no file: the thread has its person"      "$(o "lost-person-$ev")" "$P0"
  check "$ev with no file: and its session id"             "$(o "lost-session-$ev")" 'thread-2'
done

echo
echo 'the board lock, held for longer than a claim waits'
board b16 4
for i in 1 2 3 4; do standin; claim --pid "$SP" --session "old-$i"; eval "O$i=$SP"; done
for i in 1 2 3 4; do eval "gone \$O$i"; done
"$AB" sweep >/dev/null 2>&1
check 'all four names are in grace'                        "$(ledger_n)" '4'
hold_lock() {   # another process has the board lock, until free_lock
  mkdir -p "$AGENT_BOARD_DIR/locks"
  python3 "$T/hold-lock.py" "$AGENT_BOARD_DIR/locks/board.flock" "$T/held" &
  holder=$!; printf '%s\n' "$holder" >> "$T/fakes"
  local i=0; while [ ! -e "$T/held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
}
free_lock() { rm -f "$T/held"; wait "$holder" 2>/dev/null; }
standin; N1=$SP; standin; N2=$SP
hold_lock
C=""
for p in $N1 $N2; do
  ( AGENT_BOARD_LOCK_WAIT_SECS=1 "$AB" claim --agent codex --cwd "$T" --pid "$p" --session "new-$p" \
      >/dev/null 2>"$T/busy.$p"; echo "$?" > "$T/rc.$p" ) &
  C="$C $!"
done
wait $C
check 'a claim that cannot have the lock exits 75'         "$(cat "$T/rc.$N1")" '75'
check 'and so does the one that started with it'           "$(cat "$T/rc.$N2")" '75'
has   'it says that the board is busy'                     "$(cat "$T/busy.$N1")" 'the board is busy'
check 'neither wrote a session file' \
  "$([ -e "$(sfile "$N1")" ] || [ -e "$(sfile "$N2")" ] && echo there || echo none)" 'none'
check 'and no claim in the ledger was used'                "$(ledger_n)" '4'
free_lock
C=""
for p in $N1 $N2; do claim --pid "$p" --session "new-$p" & C="$C $!"; done
wait $C
has    'with the lock free, the first has a person'        "$(person "$N1")" '^Crew-[1-4]$'
has    'and the second'                                    "$(person "$N2")" '^Crew-[1-4]$'
differ 'and they are two persons'                          "$(person "$N1")" "$(person "$N2")"

echo
echo 'a claim that would replace the file of the process before it, with no ledger'
board b17 6
no_ledger()   { mv "$AGENT_BOARD_DIR/retired" "$AGENT_BOARD_DIR/retired.keep"; : > "$AGENT_BOARD_DIR/retired"; }
with_ledger() { rm -f "$AGENT_BOARD_DIR/retired"; mv "$AGENT_BOARD_DIR/retired.keep" "$AGENT_BOARD_DIR/retired"; }
standin; A=$SP
claim --pid "$A" --session s-a --name alpha --scope 'the old work'
PA=$(person "$A")
standin; B=$SP
claim --pid "$B" --session s-c --name gamma --scope 'older work'
PB=$(person "$B")
standin; Z=$SP
claim --pid "$Z" --session s-z; gone "$Z"; "$AB" sweep >/dev/null 2>&1   # the ledger directory is there
refile "$A" 's/^pstart: .*/pstart: another-start/'
refile "$B" 's/^status: .*/status: DONE/; /^pstart: /d'
no_ledger
"$AB" claim --agent codex --cwd "$T" --pid "$A" --session s-b --name beta >/dev/null 2>"$T/claim.err"; rc=$?
check 'a file of another process: the claim fails'         "$rc" '1'
has   'and says why'                                       "$(cat "$T/claim.err")" 'could not save the person'
check 'the old file stays: its session id'                 "$(field "$(sfile "$A")" session)" 's-a'
check 'its person'                                         "$(person "$A")" "$PA"
check 'and its scope'                                      "$(field "$(sfile "$A")" scope)" 'the old work'
"$AB" claim --agent codex --cwd "$T" --pid "$B" --session s-d --name delta >/dev/null 2>"$T/claim.err"; rc=$?
check 'a DONE file that names no process: the claim fails too' "$rc" '1'
check 'and that file stays: its session id'                "$(field "$(sfile "$B")" session)" 's-c'
check 'and its person'                                     "$(person "$B")" "$PB"
with_ledger
claim --pid "$A" --session s-b --name beta
check 'with the ledger back, the claim is made'            "$(field "$(sfile "$A")" session)" 's-b'
check 'and the person of the process before is in the ledger' "$(ledger_has "$PA")" '1'
differ 'not with the new session'                          "$(person "$A")" "$PA"
claim --pid "$B" --session s-d --name delta
check 'the same for the file that named no process'        "$(field "$(sfile "$B")" session)" 's-d'
check 'its person is in the ledger'                        "$(ledger_has "$PB")" '1'

echo
echo 'hooks of a Codex session when the board lock is not to be had'
board b18 8
rm -rf "$T/out" "$T/held" "$T/pause" "$T/mv-paused"; mkdir -p "$T/out" "$T/slowbin"
# A rename that waits, for the one process that has this directory first in PATH:
# the write of a field has then read the file, and has not put the new one in place.
cat > "$T/slowbin/mv" <<'EOS'
#!/bin/bash
if [ -e "$T/pause" ]; then
  : > "$T/mv-paused"
  while [ -e "$T/pause" ]; do sleep 0.05; done
fi
exec /bin/mv "$@"
EOS
chmod +x "$T/slowbin/mv"
cat > "$T/agent-lib.sh" <<'EOS'
pl() {   # pl <event> <session id> [<command>]
  EV=$1 SID=$2 A=${3:-} CWD=$T python3 -c '
import json, os
e = os.environ
d = {"session_id": e["SID"], "transcript_path": None, "cwd": e["CWD"],
     "hook_event_name": e["EV"], "model": "gpt-test", "permission_mode": "default",
     "turn_id": "t1", "reason": "other"}
if e["A"]:
    d.update(tool_name="Bash", tool_use_id="u1", tool_input={"command": e["A"]})
print(json.dumps(d))'
}
f="$AGENT_BOARD_DIR/sessions/$$.md"
fld() { sed -n "s/^$1: //p" "$f" 2>/dev/null | head -1; }
put() { printf '%s' "$2" > "$T/out/$1"; }
edit() { sed "$1" "$f" > "$f.t" && mv "$f.t" "$f"; }
# Always the last part of a pipeline. The exec puts the hook in the place of the
# subshell that the pipeline made: the hook's parent is then the stand-in agent.
hook() { exec "$AB" "hook-$1" --codex >/dev/null 2>&1; }
hold_lock() {
  mkdir -p "$AGENT_BOARD_DIR/locks"
  python3 "$T/hold-lock.py" "$AGENT_BOARD_DIR/locks/board.flock" "$T/held" &
  holder=$!
  i=0; while [ ! -e "$T/held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
}
free_lock() { rm -f "$T/held"; wait "$holder" 2>/dev/null; }
lease() { [ -d "$AGENT_BOARD_DIR/locks/env/dev1.lease" ] && echo held || echo free; }
ends() { ls "$AGENT_BOARD_DIR/locks" 2>/dev/null | grep -c '^end\.' || true; }
cd "$T"
EOS
cat > "$T/agent4.sh" <<'EOS'
. "$T/agent-lib.sh"
export AGENT_BOARD_LOCK_WAIT_SECS=1

# The start of the session cannot claim. The next tool call does.
hold_lock
pl SessionStart thread-1 | hook start
put start-busy "$([ -e "$f" ] && echo there || echo none)"
free_lock
pl PreToolUse thread-1 'true' | hook pretool
put start-after "$(fld session)"
put p0 "$(fld person)"
"$AB" scope 'first task' >/dev/null 2>&1

# No lock: a DONE session is not made live, a field is not written, a person is
# not drawn again.
"$AB" done
hold_lock
"$AB" scope 'second task' >/dev/null 2>"$T/out/scope-err"; put scope-rc "$?"
put busy-scope-status "$(fld status)"; put busy-scope "$(fld scope)"
pl PreToolUse thread-1 'true' | hook pretool
put busy-pretool "$(fld status)"
free_lock
pl PreToolUse thread-1 'true' | hook pretool
put free-pretool "$(fld status)"
edit 's/^person: .*/person: Ghost/'     # not a name of the theme: a heartbeat draws again
hold_lock
"$AB" heartbeat 2>/dev/null
put busy-person "$(fld person)"
"$AB" done 2>/dev/null; put busy-done-rc "$?"; put busy-done "$(fld status)"
free_lock
"$AB" heartbeat
put free-person "$(fld person)"

# A heartbeat that has read the file, and waits before its rename. The claim of
# the next thread comes in between.
export AGENT_BOARD_LOCK_WAIT_SECS=5
: > "$T/pause"
PATH="$T/slowbin:$PATH" "$AB" heartbeat &
hb=$!
i=0; while [ ! -e "$T/mv-paused" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
put hb-paused "$([ -e "$T/mv-paused" ] && echo paused || echo no)"
"$AB" claim --session thread-2 >/dev/null 2>&1 &
cl=$!
sleep 0.7
put paused-sid "$(fld session)"
rm -f "$T/pause"; wait "$hb" "$cl"
put after-sid "$(fld session)"
pl SessionEnd thread-1 | hook end
put after-old-end "$(fld status)"
export AGENT_BOARD_LOCK_WAIT_SECS=1

# A file that names no session (made by a command, not by a hook): its end takes
# the lock like any other.
edit 's/^session: .*/session: -/'
"$AB" env take dev1 --for 'a test' >/dev/null 2>&1
put lease-taken "$(lease)"
hold_lock
s=$(date +%s%N)
pl SessionEnd thread-9 | hook end
put dash-ms "$(( ($(date +%s%N) - s) / 1000000 ))"
put dash-locked "$(fld status)"; put dash-lease-locked "$(lease)"; put dash-ends "$(ends)"
free_lock
"$AB" sweep >/dev/null 2>&1
put dash-swept "$(fld status)"; put dash-lease-swept "$(lease)"; put dash-ends-swept "$(ends)"

# The end of the thread that has the file, with the lock held: the next hook of
# the session applies it.
pl SessionStart thread-3 | hook start
put t3-sid "$(fld session)"; put t3-status "$(fld status)"
"$AB" env take dev1 --for 'a test' >/dev/null 2>&1
hold_lock
pl SessionEnd thread-3 | hook end
put own-locked "$(fld status)"; put own-lease-locked "$(lease)"
free_lock
pl PostToolUse thread-3 'true' | hook posttool
put own-applied "$(fld status)"; put own-lease-applied "$(lease)"; put own-ends "$(ends)"

# The end of another thread of the daemon, written down the same way: it is not
# the end of the thread that has the file.
pl SessionStart thread-4 | hook start
"$AB" scope 'thread four' >/dev/null 2>&1
"$AB" env take dev1 --for 'a test' >/dev/null 2>&1
hold_lock
pl SessionEnd thread-3 | hook end
free_lock
"$AB" sweep >/dev/null 2>&1
put other-status "$(fld status)"; put other-sid "$(fld session)"
put other-lease "$(lease)"; put other-ends "$(ends)"

# An end that waits, and the start of the next thread: the end comes first.
hold_lock
pl SessionEnd thread-4 | hook end
free_lock
"$AB" claim --session thread-5 >/dev/null 2>&1
put next-sid "$(fld session)"; put next-status "$(fld status)"
put next-scope "$(fld scope)"; put next-lease "$(lease)"; put next-person "$(fld person)"
put next-ends "$(ends)"
EOS
AB="$AB" T="$T" "$T/fakebin/codex" "$T/agent4.sh" 2>"$T/out/stderr"
check 'SessionStart without the lock makes no file'        "$(o start-busy)" 'none'
check 'the next tool call makes it, with the thread id'    "$(o start-after)" 'thread-1'
if [ "$(o scope-rc)" != 0 ]; then ok '`scope` on a DONE session without the lock fails'
else bad '`scope` exited 0 without the lock'; fi
has   'and says that the board is busy'                    "$(cat "$T/out/scope-err")" 'the board is busy'
check 'the session stays DONE'                             "$(o busy-scope-status)" 'DONE'
check 'and the scope is not written'                       "$(o busy-scope)" 'first task'
check 'a tool call without the lock leaves it DONE'        "$(o busy-pretool)" 'DONE'
check 'the next one, with the lock, makes it ACTIVE'       "$(o free-pretool)" 'ACTIVE'
check 'no person is drawn again without the lock'          "$(o busy-person)" 'Ghost'
if [ "$(o busy-done-rc)" != 0 ]; then ok '`done` without the lock fails'
else bad '`done` exited 0 without the lock'; fi
check 'and writes nothing'                                 "$(o busy-done)" 'ACTIVE'
has   'with the lock, the heartbeat draws one'             "$(o free-person)" '^Crew-[1-8]$'
check 'the heartbeat waits in its rename'                  "$(o hb-paused)" 'paused'
check 'a claim does not write while it does'               "$(o paused-sid)" 'thread-1'
check 'the claim is the later write: its session id stays' "$(o after-sid)" 'thread-2'
check 'so the end of the earlier thread leaves the file ACTIVE' "$(o after-old-end)" 'ACTIVE'
check 'the session has a dev environment lease'            "$(o lease-taken)" 'held'
check 'no session id in the file, lock held: SessionEnd does not sign off' "$(o dash-locked)" 'ACTIVE'
check 'the lease stays for now'                            "$(o dash-lease-locked)" 'held'
check 'the end is written down'                            "$(o dash-ends)" '1'
ms=$(o dash-ms)
if [ "${ms:-9999}" -lt 1000 ]; then ok "inside the second Codex gives SessionEnd (${ms}ms)"
else bad "hook-end --codex took ${ms}ms with the lock held"; fi
check 'with the lock free, a sweep applies it: DONE'       "$(o dash-swept)" 'DONE'
check 'and the lease is free'                              "$(o dash-lease-swept)" 'free'
check 'the record is gone'                                 "$(o dash-ends-swept)" '0'
check 'the next thread has the file'                       "$(o t3-sid)/$(o t3-status)" 'thread-3/ACTIVE'
check 'its end with the lock held does not sign off'       "$(o own-locked)/$(o own-lease-locked)" 'ACTIVE/held'
check 'its next hook applies the end: DONE'                "$(o own-applied)" 'DONE'
check 'and the lease is free'                              "$(o own-lease-applied)" 'free'
check 'the record is gone'                                 "$(o own-ends)" '0'
check 'a written-down end of another thread leaves the file' "$(o other-status)/$(o other-sid)" 'ACTIVE/thread-4'
check 'and the lease'                                      "$(o other-lease)" 'held'
check 'and the record is gone'                             "$(o other-ends)" '0'
check 'an end that waits is applied before the claim of the next thread' "$(o next-lease)" 'free'
check 'which then starts its own file'                     "$(o next-sid)/$(o next-status)" 'thread-5/ACTIVE'
check 'without the scope of the thread that ended'         "$(o next-scope)" '-'
has   'and with a person'                                  "$(o next-person)" '^Crew-[1-8]$'
check 'no record is left'                                  "$(o next-ends)" '0'

echo
echo 'a tool hook that finds the file of another process, or of another session'
board b19 8
rm -rf "$T/out"; mkdir -p "$T/out"
cat > "$T/agent5.sh" <<'EOS'
. "$T/agent-lib.sh"
inledger() { grep -lx "person: $1" "$AGENT_BOARD_DIR"/retired/*.md 2>/dev/null | grep -c . || true; }
pl SessionStart thread-1 | hook start
p0=$(fld person); put p0 "$p0"
"$AB" scope 'the old work' >/dev/null 2>&1

# A DONE file under this pid, written by a process that started at another time.
"$AB" done
edit 's/^pstart: .*/pstart: another-start/'
pl PreToolUse thread-2 'true' | hook pretool
put stale-status "$(fld status)"; put stale-sid "$(fld session)"; put stale-scope "$(fld scope)"
put stale-person "$(fld person)"; put stale-ledger "$(inledger "$p0")"

# The same with an ACTIVE file, and a hook that is not PreToolUse.
"$AB" scope 'more old work' >/dev/null 2>&1
p1=$(fld person); put p1 "$p1"
edit 's/^pstart: .*/pstart: another-start/'
pl PostToolUse thread-3 'true' | hook posttool
put stale2-sid "$(fld session)"; put stale2-scope "$(fld scope)"
put stale2-person "$(fld person)"; put stale2-ledger "$(inledger "$p1")"

# This process's own file, DONE, and a tool call of a thread that has no file: it
# does not become that thread's past.
"$AB" scope 'work of thread three' >/dev/null 2>&1
p2=$(fld person); put p2 "$p2"
"$AB" done
pl PreToolUse thread-4 'true' | hook pretool
put own-status "$(fld status)"; put own-sid "$(fld session)"
put own-scope "$(fld scope)"; put own-person "$(fld person)"

# What is a sign-off, and what only has the words. The session is DONE each time.
pre() { "$AB" done; pl PreToolUse thread-4 "$1" | hook pretool; fld status; }
put so-comment   "$(pre 'pwd # earlier step; agentboard done')"
put so-dq-path   "$(pre '"/opt/agent board/bin/agentboard" release')"
put so-sq-path   "$(pre "'/opt/board/bin/agentboard' done")"
put so-var-path  "$(pre '"$HOME/agent-board/bin/agentboard" release')"
put so-after-comment "$(pre 'agentboard done # finished')"
put so-word-hash "$(pre 'echo a#b; agentboard done')"
put so-heredoc   "$(pre "$(printf 'cat <<EOF\nagentboard done\nEOF')")"
put so-after-heredoc "$(pre "$(printf 'cat <<EOF\nnotes\nEOF\nagentboard done')")"
put so-newline   "$(pre "$(printf 'git status\nagentboard vault free')")"
put so-subst     "$(pre 'echo "$(agentboard done)"')"
put so-bash-c    "$(pre "bash -c 'agentboard release'")"
put so-if        "$(pre 'if true; then agentboard done; fi')"
put so-redirect  "$(pre 'agentboard done >/dev/null 2>&1')"
put so-echo      "$(pre 'echo agentboard done')"
put so-arg       "$(pre 'agentboard scope "done"')"
put so-unclosed  "$(pre 'echo "agentboard done')"
put so-remote    "$(pre 'ssh somehost agentboard done')"
EOS
AB="$AB" T="$T" "$T/fakebin/codex" "$T/agent5.sh" 2>"$T/out/stderr"
P0=$(o p0)
check 'a DONE file of another process: the tool call starts a file' "$(o stale-status)" 'ACTIVE'
check 'with the id of the thread that made the call'       "$(o stale-sid)" 'thread-2'
check 'without the scope of the process before'            "$(o stale-scope)" '-'
differ 'and without its person'                            "$(o stale-person)" "$P0"
check 'which stays claimed in the ledger'                  "$(o stale-ledger)" '1'
check 'an ACTIVE file of another process, PostToolUse: the thread id' "$(o stale2-sid)" 'thread-3'
check 'not its scope'                                      "$(o stale2-scope)" '-'
differ 'not its person'                                    "$(o stale2-person)" "$(o p1)"
check 'which is in the ledger'                             "$(o stale2-ledger)" '1'
check 'own DONE file, another thread: the call starts a file' "$(o own-status)/$(o own-sid)" 'ACTIVE/thread-4'
check 'without the scope of the thread before'             "$(o own-scope)" '-'
check 'and with the person the process has'                "$(o own-person)" "$(o p2)"
check 'a sign-off after a # is a comment: the call is work' "$(o so-comment)" 'ACTIVE'
check 'a release by a path in double quotes is a sign-off' "$(o so-dq-path)" 'DONE'
check 'and by a path in single quotes'                     "$(o so-sq-path)" 'DONE'
check 'and by a path with a variable in it'                "$(o so-var-path)" 'DONE'
check 'a comment after a sign-off does not hide it'        "$(o so-after-comment)" 'DONE'
check 'a # inside a word is no comment'                    "$(o so-word-hash)" 'DONE'
check 'the body of a here-document is data'                "$(o so-heredoc)" 'ACTIVE'
check 'a sign-off after a here-document is one'            "$(o so-after-heredoc)" 'DONE'
check 'and one on the next line'                           "$(o so-newline)" 'DONE'
check 'and one in $( )'                                    "$(o so-subst)" 'DONE'
check 'and one that bash -c runs'                          "$(o so-bash-c)" 'DONE'
check 'and one in an if'                                   "$(o so-if)" 'DONE'
check 'and one with its output sent away'                  "$(o so-redirect)" 'DONE'
check 'the words as arguments of echo are data'            "$(o so-echo)" 'ACTIVE'
check 'so is a scope that says done'                       "$(o so-arg)" 'ACTIVE'
check 'quotes that do not close: the call is work'         "$(o so-unclosed)" 'ACTIVE'
check 'a sign-off on another machine is not this session'"'"'s' "$(o so-remote)" 'ACTIVE'

echo
printf 'pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]

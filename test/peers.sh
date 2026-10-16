#!/bin/bash
# Verifies the peer layer: export/import, the mirrored roster, messages carried
# both ways with no echo and no loss, names unique across machines, and that a
# board with no machines.local behaves exactly as before.
#
# Two throwaway boards stand in for two machines, and a stub `ssh` runs the
# "remote" command locally, so no real host is involved.
#
#   ~/agent-board/test/peers.sh
set -uo pipefail

AB=${AB:-$HOME/agent-board/bin/agentboard}
BIN=$(cd "$(dirname "$AB")" && pwd -P)
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentboard-peers.XXXXXX")" && pwd -P)
A="$T/alpha"; B="$T/beta"
mkdir -p "$A/bin" "$B/bin" "$T/cc" "$T/stub"
for b in "$A" "$B"; do
  for f in agentboard agentboard-peer deploylock; do ln -s "$BIN/$f" "$b/bin/$f"; done
done
export AGENT_BOARD_CC_SESSIONS="$T/cc"

# ssh <opts...> <host> <command>: run the command here. The host is ignored; the
# command carries the peer's AGENT_BOARD_DIR, which is all that tells them apart.
cat > "$T/stub/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 1 ]; do shift; done
exec bash -c "$1"
EOF
chmod +x "$T/stub/ssh"
export AGENT_BOARD_SSH="$T/stub/ssh"

cat > "$A/machines.local" <<EOF
[local]
label = alpha

[peer]
label = beta
ssh   = beta-host
board = $B
hub   = yes

[relay]
interval = 5
stale    = 60
EOF
# beta cannot reach alpha: alpha's relay drives both directions.
cat > "$B/machines.local" <<EOF
[local]
label = beta

[peer]
label = alpha
EOF

FAKES=()
cleanup() { for p in ${FAKES+"${FAKES[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()  { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1 — no /$3/ in: $2"; fi; }
hasnt(){ if printf '%s' "$2" | grep -q -- "$3"; then bad "$1 — unexpected /$3/ in: $2"; else ok "$1"; fi; }

ab()  { AGENT_BOARD_DIR="$1" "$AB" "${@:2}"; }
fake() {   # fake <board> <name> <person> -> pid of a live stand-in agent
  local p
  sleep 3000 >/dev/null 2>&1 & p=$!; disown "$p" 2>/dev/null; FAKES+=("$p")
  ab "$1" claim --pid "$p" --agent codex --cwd "$T" --name "$2" --scope "work of $2" >/dev/null
  sed -i.bak "s/^person: .*/person: $3/" "$1/sessions/$p.md"
  printf '%s' "$p"
}
relay() { ab "$A" relay --once; }
msgfile() {   # msgfile <board> <from-pid> <from-name> <to> <text>
  local id; id="$(date +%s).$2.$RANDOM.md"
  cat > "$1/messages/$id" <<EOF
from_pid: $2
from_name: $3
from_agent: codex
to: $4
repo: -
epoch: $(date +%s)
time: $(date +%Y-%m-%dT%H:%M:%S%z)

$5
EOF
  printf '%s' "$id"
}

PA=$(fake "$A" lamp Hawkeye)
PB=$(fake "$B" anvil Groot)

echo 'without a relay, nothing crosses'
out=$(ab "$A" list 2>&1)
has   'alpha sees its own agent' "$out" 'lamp'
has   'and says the peer has never synced' "$out" 'beta: never synced'
hasnt 'and does not invent remote agents' "$out" 'anvil'

echo
echo 'export'
out=$(ab "$B" export)
has 'export is JSON with the label'   "$out" '"label": "beta"'
has 'and carries the live session'    "$out" '"name": "anvil"'
has 'with its person'                 "$out" '"person": "Groot"'

echo
echo 'one relay pass mirrors both ways'
out=$(relay 2>&1)
has 'relay reports success' "$out" 'beta ok'
out=$(ab "$A" list 2>&1)
has 'alpha now lists the beta agent, qualified' "$out" 'anvil@beta'
has 'with its scope'                          "$out" 'work of anvil'
has 'and how fresh the mirror is'             "$out" 'beta: 1 agent(s), synced'
out=$(ab "$B" list 2>&1)
has 'beta lists the alpha agent'              "$out" 'lamp@alpha'
has 'and the board counts remote agents' "$(ab "$A" board 2>&1)" '2 agents working'

echo
echo 'messages across'
id1=$(msgfile "$A" "$PA" lamp 'anvil@beta' 'please hold the deploy')
id2=$(msgfile "$A" "$PA" lamp '*' 'broadcast from alpha')
idb=$(msgfile "$B" "$PB" anvil '*' 'broadcast from beta')
relay >/dev/null 2>&1
[ -f "$B/messages/$id1" ] && ok 'a directed message lands on beta, same id' || bad 'directed message missing on beta'
has 'addressed to the local pid there' "$(cat "$B/messages/$id1" 2>/dev/null)" "to: $PB"
has 'stamped with its origin'          "$(cat "$B/messages/$id1" 2>/dev/null)" 'origin: alpha'
[ -f "$B/messages/$id2" ] && ok 'a broadcast lands on beta'  || bad 'broadcast missing on beta'
[ -f "$A/messages/$idb" ] && ok 'a beta broadcast lands on alpha' || bad 'beta broadcast missing on alpha'
has 'and is attributed with its machine' "$(cat "$A/messages/$idb")" 'origin: beta'
nA=$(ls "$A/messages" | grep -c .); nB=$(ls "$B/messages" | grep -c .)
relay >/dev/null 2>&1; relay >/dev/null 2>&1
check 'no echo: a second and third pass add nothing on alpha' "$(ls "$A/messages" | grep -c .)" "$nA"
check 'nor on beta'                                         "$(ls "$B/messages" | grep -c .)" "$nB"
hasnt 'alpha never re-imports its own message as foreign' "$(cat "$A/messages/$id1")" 'origin:'

# `inbox` is tied to the caller's own session; `msgs` renders the same line.
out=$(ab "$B" msgs 2>&1)
has 'rendered with name@origin'     "$out" 'lamp@alpha (codex)'
has 'and to the beta agent by name' "$out" 'to anvil'

echo
echo 'tell by name reaches the peer'
# A session of our own on alpha, so tell has a sender.
out=$(cd "$T" && ab "$A" tell anvil 'are you on the role yet' 2>&1)
has 'tell resolves a remote-only name to name@machine' "$out" 'anvil@beta'
has 'and says the relay carries it'                    "$out" 'next sync'
out=$(cd "$T" && ab "$A" tell groot 'person names work too' 2>&1)
has 'a remote person resolves, case-folded'            "$out" 'groot@beta'
out=$(cd "$T" && ab "$A" tell anvil@beta 'qualified' 2>&1)
has 'name@machine is accepted'                         "$out" 'anvil@beta'
out=$(cd "$T" && ab "$A" tell anvil@nowhere 'x' 2>&1); rc=$?
check 'an unknown machine is refused' "$rc" 1
out=$(cd "$T" && ab "$A" tell lamp@alpha 'to myself, qualified' 2>&1)
has 'my own label resolves locally' "$out" "pid $PA"
relay >/dev/null 2>&1
n=$(grep -l 'are you on the role yet' "$B"/messages/*.md 2>/dev/null | grep -c .)
check 'the tell arrives on beta exactly once' "$n" 1

echo
echo 'the same name on both machines must be qualified'
PA2=$(fake "$A" twin Thor); PB2=$(fake "$B" twin Loki)
relay >/dev/null 2>&1
out=$(cd "$T" && ab "$A" tell twin 'which one' 2>&1); rc=$?
check 'an ambiguous name is refused' "$rc" 1
has   'and the refusal says how to qualify it' "$out" 'twin@<machine>'
out=$(cd "$T" && ab "$A" tell twin@beta 'this one' 2>&1)
has   'qualified, it goes'                     "$out" 'twin@beta'

echo
echo 'names are issued unique across machines'
# Groot is live on beta; a new alpha session must not be handed the same person.
taken=$(cut -f2 "$A/remote/beta/sessions.tsv" | sort -u | tr '\n' ' ')
for _ in 1 2 3 4 5 6; do
  p=$(fake "$A" "n$RANDOM" placeholder)
  sed -i.bak '/^person: /d' "$A/sessions/$p.md"
  ab "$A" claim --pid "$p" --agent codex --cwd "$T" >/dev/null
  got=$(sed -n 's/^person: //p' "$A/sessions/$p.md")
  case " $taken " in *" $got "*) bad "issued $got, which is live on beta"; break ;; esac
done
ok 'no person live on beta was issued on alpha'

echo
echo 'a stale mirror is not shown as live'
echo $(( $(date +%s) - 3600 )) > "$A/remote/beta/synced"
out=$(ab "$A" list 2>&1)
has   'says when it was last seen' "$out" 'beta: not seen since'
hasnt 'and does not list its agents' "$out" 'anvil@beta'
out=$(cd "$T" && ab "$A" tell anvil@beta 'x' 2>&1); rc=$?
check 'and a tell to it is refused, not queued blind' "$rc" 1
relay >/dev/null 2>&1
has 'the next pass brings it back' "$(ab "$A" list 2>&1)" 'anvil@beta'

echo
echo 'a failing link is reported, not hidden'
cat > "$T/stub/ssh-down" <<'EOF'
#!/bin/bash
echo "ssh: connect to host beta-host: Connection refused" >&2; exit 255
EOF
chmod +x "$T/stub/ssh-down"
out=$(AGENT_BOARD_SSH="$T/stub/ssh-down" ab "$A" relay --once 2>&1)
has 'relay says it failed'   "$out" 'beta FAILED'
has 'peers shows the error'  "$(ab "$A" peers)" 'Connection refused'

echo
echo 'wins cross as a view'
mkdir -p "$B/wins"
printf '%s\tGroot\tthe role landed\n' "$(date +%H:%M:%S)" > "$B/wins/$(date +%F).$PB"
relay >/dev/null 2>&1
has 'a beta win shows on alpha, with its machine' "$(ab "$A" wins 2>&1)" 'Groot@beta'

out=$(ab "$B" relay --once 2>&1); rc=$?
check 'a board that reaches no peer has nothing to relay' "$rc" 1

echo
echo 'with no machines.local, the board is on its own'
mv "$A/machines.local" "$A/machines.off"
out=$(ab "$A" list 2>&1)
hasnt 'no peer lines'       "$out" 'beta'
has   'local agents as ever' "$out" 'lamp'
has   'peers says so'        "$(ab "$A" peers)" 'on its own'
ab "$A" sweep >/dev/null 2>&1
[ -d "$A/remote/beta" ] && bad 'sweep keeps a mirror nobody configures' || ok 'sweep drops mirrors once peers are off'
mv "$A/machines.off" "$A/machines.local"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]

#!/bin/bash
# Verifies persistent.local: a session named there stays live and survives sweep
# however old its heartbeat, as long as its pid runs; a dead pid still drops it;
# and a session not named there keeps the heartbeat rule.
#
# The stand-ins are plain `sleep` processes, not agents, so sweep's "a live agent
# that sat idle" rule cannot be what keeps them.
#
#   ~/agent-board/test/persistent.sh
set -uo pipefail

AB=${AB:-$HOME/agent-board/bin/agentboard}
export AGENT_BOARD_DIR AGENT_BOARD_CC_SESSIONS
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentboard-persist.XXXXXX")" && pwd -P)
AGENT_BOARD_DIR="$T/board"
AGENT_BOARD_CC_SESSIONS="$T/cc"
mkdir -p "$AGENT_BOARD_DIR" "$AGENT_BOARD_CC_SESSIONS"
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

fake() {   # fake <name> -> pid of a stand-in whose heartbeat is days old
  { trap - EXIT; exec sleep 3000; } </dev/null >/dev/null 2>&1 &
  local p=$!
  disown "$p" 2>/dev/null
  FAKES+=("$p")
  "$AB" claim --pid "$p" --agent codex --cwd "$T" --name "$1" >/dev/null
  sed -i.bak "s/^epoch: .*/epoch: 1/" "$AGENT_BOARD_DIR/sessions/$p.md"
  printf '%s' "$p"
}
kept() { [ -f "$AGENT_BOARD_DIR/sessions/$1.md" ] && echo kept || echo gone; }

cat > "$AGENT_BOARD_DIR/persistent.local" <<'P'
# all-day sessions
  chief-of-staff
jarvis-remote
P

COS=$(fake chief-of-staff)
JV=$(fake jarvis-remote)
ORD=$(fake ordinary)

out=$("$AB" list 2>&1)
want    'a persistent session with an old heartbeat is live'        'chief-of-staff' "$out"
want    'a name is matched with its whitespace trimmed'             'jarvis-remote'  "$out"
wantnot 'an ordinary session with an old heartbeat is not live'     'ordinary'       "$out"
wantnot 'tell reaches a persistent session that sat idle'           'no live' \
  "$("$AB" tell chief-of-staff 'ping' 2>&1)"
want    'and its export carries it to other machines'               'chief-of-staff' \
  "$("$AB" _export | grep '^S')"

# A crash: the pid is gone, so persistence buys nothing.
kill "$JV" 2>/dev/null; wait "$JV" 2>/dev/null
wantnot 'a persistent session whose pid died is not live'           'jarvis-remote'  "$("$AB" list 2>&1)"

"$AB" sweep >/dev/null
want 'sweep keeps a persistent session while its pid runs'          'kept' "$(kept "$COS")"
want 'sweep drops a persistent session whose pid died'              'gone' "$(kept "$JV")"
want 'sweep still drops an ordinary stale session'                  'gone' "$(kept "$ORD")"

# Without the file, the heartbeat rule is back for everyone.
rm -f "$AGENT_BOARD_DIR/persistent.local"
wantnot 'with no persistent.local, an old heartbeat is not live'    'chief-of-staff' "$("$AB" list 2>&1)"
"$AB" sweep >/dev/null
want 'and sweep drops it'                                           'gone' "$(kept "$COS")"

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

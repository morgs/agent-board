#!/bin/bash
# Verifies bin/deploylock: how a command resolves to an environment or a global
# lock, and that the reader-writer locks behave — parallel on different hosts,
# queued on the same one, a global run excluding everything, a queued global run
# not starved, and a killed wrapper not releasing a deploy that is still running.
#
# Self-contained: a fake ansible-playbook and ansible on PATH answer --list-hosts
# from a tiny made-up inventory, inside a throwaway AGENT_BOARD_DIR.
#
#   ~/agent-board/test/deploylock.sh
set -uo pipefail

DL=${DL:-$HOME/agent-board/bin/deploylock}
AB=${AB:-$HOME/agent-board/bin/agentboard}
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/deploylock.XXXXXX")" && pwd -P)
export AGENT_BOARD_DIR="$T/board" AGENT_BOARD_CC_SESSIONS="$T/cc"
export AGENT_BOARD_AGENT="Tester · t1" FAKE_LOG="$T/ran.log"
mkdir -p "$AGENT_BOARD_DIR" "$AGENT_BOARD_CC_SESSIONS" "$T/bin" "$T/deploy/roles/relay/tasks"
BG=()
cleanup() {
  for p in ${BG+"${BG[@]}"}; do kill "$p" 2>/dev/null; done
  pkill -f "$T/bin/ansible-playbook" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

pass=0; fail=0
want() {     # want <label> <expected substring> <actual>
  case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok    %s\n' "$1" ;;
    *) fail=$((fail+1)); printf '  FAIL  %s\n          wanted: %s\n          got:    %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' '|')" ;;
  esac
}

# Inventory: app1 app2 dev1 dev2 backup1; group web = app1 app2; group backups = backup1.
cat > "$T/bin/ansible-playbook" <<'FAKE'
#!/bin/bash
limit=""; target=""; list=0; pb=""
while [ $# -gt 0 ]; do
  case $1 in
    -l|--limit) limit=$2; shift 2 ;;
    --limit=*)  limit=${1#--limit=}; shift ;;
    -e)         case $2 in target_host=*) target=${2#target_host=} ;; esac; shift 2 ;;
    -i)         shift 2 ;;
    --list-hosts) list=1; shift ;;
    *.yml)      pb=$1; shift ;;
    *)          shift ;;
  esac
done
if [ "$list" = 0 ]; then
  echo "start $pb $target$limit" >> "$FAKE_LOG"; sleep "${FAKE_SLEEP:-0}"
  echo "end $pb $target$limit" >> "$FAKE_LOG"; exit 0
fi
[ "$limit" = nosuch ] && { echo 'ERROR! no hosts to target' >&2; exit 1; }
play() {   # play <n> <pattern> <role> hosts...
  local n=$1 pat=$2 role=$3; shift 3
  printf '  play #%s (%s): x\tTAGS: []\n    pattern: [%s]\n    hosts (%s):\n' "$n" "$pat" "$pat" "$#"
  for h in "$@"; do printf '      %s\n' "$h"; done
  printf '    tasks:\n      %s : a task\tTAGS: []\n\n' "$role"
}
printf 'playbook: %s\n\n' "$pb"
case $pb in
  refresh.yml)
    play 1 localhost guard localhost
    if [ -z "$limit" ] || [ "$limit" = "$target" ]; then play 2 "$target" load "$target"; fi
    if [ -z "$limit" ]; then play 3 backups recover backup1; else play 3 backups recover; fi ;;
  *)
    case $limit in web) set -- app1 app2 ;; *) IFS=, read -r -a hs <<< "$limit"; set -- "${hs[@]}" ;; esac
    play 1 all common "$@"
    # A play the limit empties: its role delegates, and must not count.
    play 2 relays relay
    if [ "$pb" = delegating.yml ]; then play 3 all relay "$@"; fi ;;
esac
FAKE
cat > "$T/bin/ansible" <<'FAKE'
#!/bin/bash
case $1 in backups) printf '  hosts (1):\n    backup1\n' ;; *) exit 1 ;; esac
FAKE
chmod +x "$T/bin/ansible-playbook" "$T/bin/ansible"
export PATH="$T/bin:$PATH"

cd "$T/deploy" || exit 1
printf -- '- hosts: all\n  roles: [common]\n' > site.yml
cp site.yml delegating.yml
printf '# deploylock: global\n- hosts: all\n' > pinned.yml
printf '# deploylock: shared backups\n- hosts: "{{ target_host }}"\n' > refresh.yml
printf -- '- name: enrol\n  delegate_to: "{{ hub }}"\n  command: x\n' > roles/relay/tasks/main.yml

x() { "$DL" --explain "$@" 2>&1; }
wait_owner() {   # wait_owner <file> — a background run has its locks
  local i=0
  while [ ! -s "$AGENT_BOARD_DIR/locks/$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
}
idle() {         # idle — every background run has finished
  for p in ${BG+"${BG[@]}"}; do wait "$p" 2>/dev/null; done; BG=()
}

echo 'resolution — which lock a command gets'
want 'one host in --limit is an environment'   'environment lock on app1' "$(x ansible-playbook site.yml -l app1)"
want 'so is --limit=host'                      'environment lock on app1' "$(x ansible-playbook site.yml --limit=app1)"
want 'an inventory file is not a playbook'     'environment lock on app1' "$(x ansible-playbook -i inv.yml site.yml -l app1)"
want 'a comma list is global'                  'global lock — 2 target hosts' "$(x ansible-playbook site.yml -l app1,app2)"
want 'a group that expands to two is global'   'global lock — 2 target hosts' "$(x ansible-playbook site.yml -l web)"
want 'no --limit is global'                    'global lock — no --limit' "$(x ansible-playbook site.yml)"
want 'an unresolvable limit is global'         'global lock — target could not be resolved' "$(x ansible-playbook site.yml -l nosuch)"
want 'a role that delegates away is global'    'delegates to {{ hub }}' "$(x ansible-playbook delegating.yml -l app1)"
want 'a playbook can pin itself global'        'declares deploylock: global' "$(x ansible-playbook pinned.yml -l app1)"
want 'shared hosts lock beside the target'     'environment lock on dev1 (shared: backup1)' \
  "$(x ansible-playbook refresh.yml -e target_host=dev1)"
want 'anything but ansible-playbook is global' 'not an ansible-playbook run' "$(x ./other.sh)"
want '--global skips resolution'               'global lock — --global' "$(x --global ansible-playbook site.yml -l app1)"

echo
echo 'readers and writers'
FAKE_SLEEP=3 "$DL" ansible-playbook site.yml -l app1 >/dev/null 2>&1 & BG+=($!)
wait_owner deploy.app1.owner
out=$("$DL" ansible-playbook site.yml -l app2 2>&1); rc=$?
want 'a run on another host goes alongside'  '0' "$rc"
out=$("$DL" ansible-playbook site.yml -l app1 2>&1); rc=$?
want 'a run on the same host is refused'     '1' "$rc"
want 'and names who holds that host'         'agent:   Tester · t1' "$out"
out=$("$DL" ansible-playbook site.yml 2>&1); rc=$?
want 'a global run is refused'               '1' "$rc"
want 'and says environment runs hold it'     'shared by environment runs' "$out"
out=$("$DL" --status 2>&1); rc=$?
want 'status lists the environment holder'   "shared by 1 environment run" "$out"
want 'with its environment'                  'env app1: held by pid' "$out"
want 'status exits 1 while anything is held' '1' "$rc"
want 'brief status gives one line per holder' "$(printf 'app1\tTester · t1')" "$("$DL" --status --brief)"
out=$("$DL" --wait 15 ansible-playbook site.yml 2>&1); rc=$?
want 'a global run with --wait gets in after' '0' "$rc"
want 'and only after the environment run ended' 'end site.yml app1' "$(grep -B1 '^start site.yml $' "$FAKE_LOG" | head -1)"
idle

FAKE_SLEEP=3 "$DL" ansible-playbook site.yml >/dev/null 2>&1 & BG+=($!)
wait_owner deploy.owner
out=$("$DL" ansible-playbook site.yml -l app2 2>&1); rc=$?
want 'a global run keeps environment runs out' '1' "$rc"
want 'and says so'                             'held by a global run' "$out"
want 'status shows the global holder'          "lock 'deploy': global, held by pid" "$("$DL" --status)"
idle

echo
echo 'shared hosts, and a queued global run'
FAKE_SLEEP=3 "$DL" ansible-playbook refresh.yml -e target_host=dev1 >/dev/null 2>&1 & BG+=($!)
wait_owner deploy.dev1.owner
out=$("$DL" ansible-playbook refresh.yml -e target_host=dev2 2>&1); rc=$?
want 'two refreshes compete for the shared host' '1' "$rc"
want 'and the second names it'                   "'deploy' env backup1" "$out"
want 'the holder shows its shared hosts'         'shared:  backup1' "$("$DL" --status)"
"$DL" --wait 15 ansible-playbook site.yml >/dev/null 2>&1 & BG+=($!)
sleep 1.5
out=$("$DL" ansible-playbook site.yml -l app2 2>&1); rc=$?
want 'a queued global run is not overtaken'      '1' "$rc"
want 'and the late run is told why'              'a global run is queued ahead' "$out"
idle

echo
echo 'a killed wrapper does not release a running deploy'
FAKE_SLEEP=4 "$DL" ansible-playbook site.yml -l app1 >/dev/null 2>&1 &
w=$!
wait_owner deploy.app1.owner
sleep 0.5
kill -9 "$w"; wait "$w" 2>/dev/null
out=$("$DL" ansible-playbook site.yml -l app1 2>&1); rc=$?
want 'the deploy still holds its host'       '1' "$rc"
want 'and status still names it'             'env app1: held by pid' "$("$DL" --status)"
i=0; while pgrep -f "$T/bin/ansible-playbook site.yml -l app1" >/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i+1)); done
want 'once it ends, the lock is free'        "lock 'deploy': free" "$("$DL" --status)"
want 'and sweep clears the orphaned owner'   'orphaned deploy-lock owner' "$("$AB" sweep)"
want 'leaving the lock files in place'       'deploy.app1.lock' "$(ls "$AGENT_BOARD_DIR/locks")"

echo
echo 'naming the holder'
want 'whoami --known does not register a session' '1' \
  "$(AGENT_BOARD_AGENT= "$AB" whoami --known >/dev/null 2>&1; echo $?)"
want 'and leaves no session behind' '0' "$(ls "$AGENT_BOARD_DIR/sessions" 2>/dev/null | wc -l | tr -d ' ')"

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

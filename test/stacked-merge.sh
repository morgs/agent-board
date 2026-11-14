#!/bin/bash
# Verifies the stacked-PR gate in hook-pretool: `gh pr merge <lower> --delete-branch`
# deletes the branch the upper PR of a hand-chained stack is based on, and GitHub
# then closes the upper PR. The gate asks GitHub (a fake gh here) and refuses.
#
# Self-contained, like policy-matrix.sh: a throwaway AGENT_BOARD_DIR, a throwaway
# repo, and a fake gh on PATH that logs every call and answers by $GH_MODE.
#
#   ~/agent-board/test/stacked-merge.sh
set -uo pipefail

AB=${AB:-$HOME/agent-board/bin/agentboard}
export AGENT_BOARD_DIR AGENT_BOARD_CC_SESSIONS GH_LOG GH_MODE
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentboard-stack.XXXXXX")" && pwd -P)
AGENT_BOARD_DIR="$T/board"
AGENT_BOARD_CC_SESSIONS="$T/cc"
GH_LOG="$T/gh.log"
mkdir -p "$AGENT_BOARD_DIR" "$AGENT_BOARD_CC_SESSIONS" "$T/bin" "$T/nogh"
trap 'rm -rf "$T"' EXIT

R="$T/app"
mkdir -p "$R"; git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'x\n' > "$R/README.md"; git -C "$R" add README.md; git -C "$R" commit -qm init

# The fake gh. stacked: PR #5 (feat/lower, base main) has open PR #6 on top.
# none: nothing on top. fail: gh exits 1 (offline, no auth). garbage: not JSON.
# slow: hangs past the gate's timeout.
cat > "$T/bin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$GH_MODE" in
  fail) echo 'error connecting to api.github.com' >&2; exit 1 ;;
  garbage) echo 'this is not json'; exit 0 ;;
  slow) sleep 30; exit 0 ;;
esac
case "$*" in
  "pr view"*) echo '{"number":5,"headRefName":"feat/lower","baseRefName":"main","url":"https://github.com/acme/app/pull/5","isCrossRepository":false}' ;;
  "pr list"*"--base feat/lower"*)
    if [ "$GH_MODE" = stacked ]; then echo '[{"number":6,"title":"upper half"},{"number":7,"title":"top"}]'; else echo '[]'; fi ;;
  *) echo '[]' ;;
esac
GH
chmod +x "$T/bin/gh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

OUT=""
hook() {   # hook <command> [PATH] -> exit status; stderr in $OUT
  local payload
  payload=$(CWD="$R" CMD="$1" python3 -c \
    'import json,os;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}))')
  OUT=$(printf '%s' "$payload" | (cd "$R" && PATH="${2:-$T/bin:$PATH}" "$AB" hook-pretool) 2>&1 >/dev/null)
}

run() {    # run <mode> <command> <expected exit> [PATH]
  local got
  GH_MODE=$1; : > "$GH_LOG"
  hook "$2" "${4:-}"; got=$?
  if [ "$got" = "$3" ]; then ok "($got) [$1] $2"; else bad "want $3 got $got: [$1] $2"; fi
}

calls() { wc -l < "$GH_LOG" | tr -d " "; }
want() {   # want <label> <substring> <text>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — wanted: $2 — got: $(printf '%s' "$3" | tr '\n' '|')" ;; esac
}

echo 'refused: the lower PR of a stack, with its branch deleted'
run stacked 'gh pr merge 5 --merge --delete-branch' 2
want 'names the upper PRs'           '#6  upper half' "$OUT"
want 'and every one of them'         '#7  top' "$OUT"
want 'gives the retarget command'    'gh api -X PATCH repos/acme/app/pulls/6 -f base=main' "$OUT"
want 'and the other way out'         'merge without --delete-branch' "$OUT"
[ "$(calls)" = 2 ] && ok 'two gh calls, no more' || bad "gh called $(calls) times"
run stacked 'gh pr merge 5 -d --squash' 2
run stacked 'gh pr merge 5 -sd' 2
run stacked 'gh pr merge 5 -m -d -R acme/app' 2
grep -q 'pr view 5 -R acme/app' "$GH_LOG" && ok 'passes -R on to gh' || bad "-R not passed: $(cat "$GH_LOG")"
run stacked 'gh pr merge --repo=acme/app 5 --delete-branch' 2
grep -q 'pr view 5 -R acme/app' "$GH_LOG" && ok 'passes --repo= on to gh' || bad "--repo= not passed: $(cat "$GH_LOG")"
run stacked 'gh pr merge https://github.com/acme/app/pull/5 --merge --delete-branch' 2
grep -q 'pr view https://github.com/acme/app/pull/5' "$GH_LOG" && ok 'a PR URL is looked up as is' || bad "url: $(cat "$GH_LOG")"
run stacked 'gh pr merge feat/lower --merge --delete-branch' 2
run stacked 'gh pr merge --merge --delete-branch' 2
grep -q '^pr view --json' "$GH_LOG" && ok 'no PR argument: the current branch' || bad "no-arg: $(cat "$GH_LOG")"
grep -q 'pr list -R acme/app --base feat/lower --state open' "$GH_LOG" && ok 'asks the PR repo for open PRs on the head' || bad "list: $(cat "$GH_LOG")"
run stacked 'cd /tmp && gh pr merge 5 --delete-branch' 2
run stacked 'GH_REPO=acme/app gh pr merge 5 --delete-branch' 2

echo
echo 'allowed'
run none    'gh pr merge 5 --merge --delete-branch' 0
run stacked 'gh pr merge 5 --merge' 0
[ "$(calls)" = 0 ] && ok 'without --delete-branch gh is not called' || bad "gh called $(calls) times"
run stacked 'gh pr merge 5 --merge --delete-branch=false' 0
run stacked 'gh pr merge 5 -s && git branch -d feat/lower' 0
run stacked 'git log --oneline && echo "gh pr merge 5 --delete-branch"' 0
[ "$(calls)" = 0 ] && ok 'a quoted mention is not a merge' || bad "gh called $(calls) times"
run stacked 'gh pr view 5 -d' 0
run stacked 'AGENT_BOARD_OVERRIDE=1 gh pr merge 5 --delete-branch' 0

echo
echo 'fails open: when GitHub cannot answer, the merge goes ahead'
run fail    'gh pr merge 5 --merge --delete-branch' 0
run garbage 'gh pr merge 5 --merge --delete-branch' 0
run stacked 'gh pr merge 5 --merge --delete-branch' 0 "$T/nogh:/usr/bin:/bin"
start=$(date +%s)
run slow    'gh pr merge 5 --merge --delete-branch' 0
[ $(( $(date +%s) - start )) -lt 15 ] && ok 'a hung gh is cut off well inside the hook budget' || bad 'a hung gh held the hook'

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

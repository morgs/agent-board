#!/bin/bash
# Verifies `agentboard worktrees --clean` and `--dry-run`: the cleanup the report
# prints for a MERGED-and-clean verdict is run, exactly, and everything else is
# skipped with its reason.
#
# Self-contained: a throwaway AGENT_BOARD_DIR, a throwaway repo named app with a
# bare origin, and a fake gh on PATH for the PR lookups.
#
#   ~/agent-board/test/worktrees-clean.sh
set -uo pipefail

AB=${AB:-$HOME/agent-board/bin/agentboard}
export AGENT_BOARD_DIR AGENT_BOARD_CC_SESSIONS
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentboard-wtclean.XXXXXX")" && pwd -P)
AGENT_BOARD_DIR="$T/board"
AGENT_BOARD_CC_SESSIONS="$T/cc"
mkdir -p "$AGENT_BOARD_DIR" "$AGENT_BOARD_CC_SESSIONS" "$T/bin"
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
yes_() { if eval "$2"; then pass=$((pass+1)); printf '  ok    %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; fi; }

fake() {   # fake <dir> <scope> -> pid of a live "agent" working in <dir>
  { trap - EXIT; exec sleep 3000; } </dev/null >/dev/null 2>&1 &
  local p=$!
  disown "$p" 2>/dev/null
  FAKES+=("$p")
  "$AB" claim --pid "$p" --agent codex --cwd "$1" --scope "$2" >/dev/null
  printf '%s' "$p"
}

# The fake gh: feat/squashed was merged by PR #42; open PR #9 is based on
# feat/stacked. Everything else: no PRs.
cat > "$T/bin/gh" <<'GH'
#!/bin/sh
case "$*" in
  *"--head feat/squashed"*"--state merged"*) echo '[{"number":42,"baseRefName":"main"}]' ;;
  *"--base feat/stacked"*"--state open"*)    echo '[{"number":9}]' ;;
  *) echo '[]' ;;
esac
GH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

O="$T/app"
git init -q --bare -b main "$T/origin.git"
mkdir -p "$O"; git -C "$O" init -q -b main
git -C "$O" config user.email t@t; git -C "$O" config user.name t
printf 'x\n' > "$O/README.md"; printf '*.db\n__pycache__/\n' > "$O/.gitignore"
git -C "$O" add README.md .gitignore; git -C "$O" commit -qm init
git -C "$O" remote add origin "$T/origin.git"; git -C "$O" push -q origin main

wt() {   # wt <name> [merge|squash|open] [push]: a sibling worktree on feat/<name>
  git -C "$O" worktree add -q -b "feat/$1" "$T/app-$1" main 2>/dev/null
  printf '%s\n' "$1" > "$T/app-$1/$1.txt"
  git -C "$T/app-$1" add "$1.txt"; git -C "$T/app-$1" commit -qm "$1"
  [ "${3:-}" = push ] && git -C "$T/app-$1" push -q origin "feat/$1" 2>/dev/null
  case "${2:-merge}" in
    merge)  git -C "$O" merge -q --no-ff -m "merge $1" "feat/$1" ;;
    squash) git -C "$O" merge -q --squash "feat/$1" >/dev/null && git -C "$O" commit -qm "squash $1" ;;
  esac
}

wt plain   merge push    # merged, on origin           -> all three go
wt stacked merge push    # merged, an open PR on it    -> origin/feat/stacked stays
wt local                 # merged, never pushed        -> no remote step
wt squashed squash       # merged by PR #42            -> branch -D
wt dirty;    printf 'more\n' >> "$T/app-dirty/dirty.txt"
wt untracked; printf 'new\n' > "$T/app-untracked/notes.txt"
wt data;     printf 'rows\n' > "$T/app-data/local.db"
wt cache;    mkdir -p "$T/app-cache/__pycache__"; printf 'x' > "$T/app-cache/__pycache__/m.pyc"
wt open open             # not merged
wt busy;     fake "$T/app-busy" 'busy in its own tree' >/dev/null
wt self                  # this test is the agent that made it
"$AB" claim --pid "$$" --agent claude --cwd "$T/app-self" --scope 'mine' >/dev/null
mkdir -p "$T/elsewhere"
git -C "$O" worktree add -q -b feat/other "$T/elsewhere/tree" main 2>/dev/null

echo 'the report alone removes nothing'
out=$(cd "$O" && "$AB" worktrees)
want 'it still prints the verdicts'   'MERGED and clean -> git worktree remove' "$out"
want 'the branch commands name the main checkout' "git -C $O branch -d feat/plain" "$out"
yes_ 'and every tree is still there'  '[ -d "$T/app-plain" ]'

echo
echo '--dry-run: the same plan, nothing done'
out=$(cd "$O" && "$AB" worktrees --dry-run)
want 'a merged, clean tree: would remove'   "would remove  $T/app-plain [feat/plain]  git worktree remove $T/app-plain && git -C $O branch -d feat/plain && git -C $O push origin --delete feat/plain" "$out"
want 'never pushed: no remote step'          "git -C $O branch -d feat/local  (not on origin)" "$out"
want 'the PR-based one keeps its remote'     'origin/feat/stacked is left: open PR #9 is based on it' "$out"
want 'squash-merged: -D, as printed'         'branch -D feat/squashed' "$out"
want 'dirty: skipped'                        "skipped  $T/app-dirty [feat/dirty]  (branch merged BUT the tree is dirty" "$out"
want 'untracked: skipped'                    "skipped  $T/app-untracked [feat/untracked]  (branch merged BUT the tree is dirty" "$out"
want 'ignored data: skipped, and named'      "skipped  $T/app-data [feat/data]  (ignored files that are not a cache: local.db" "$out"
want 'ignored cache only: would go'          "would remove  $T/app-cache" "$out"
want 'unmerged: skipped'                     "skipped  $T/app-open [feat/open]  (branch not merged into main yet)" "$out"
want 'another agent in it: skipped'          "skipped  $T/app-busy [feat/busy]  (an agent is working here)" "$out"
want 'my own tree is not "an agent"'          "would remove  $T/app-self" "$out"
want 'another tool'"'"'s tree: skipped'          "skipped  $T/elsewhere/tree [feat/other]  (another tool manages this one" "$out"
yes_ 'nothing was removed'                   '[ -d "$T/app-plain" ] && git -C "$O" rev-parse -q --verify feat/plain >/dev/null'
yes_ '--clean --dry-run is a dry run too'    '(cd "$O" && "$AB" worktrees --clean --dry-run) | grep -q "would remove" && [ -d "$T/app-plain" ]'

echo
echo 'standing in a tree: not that one'
out=$(cd "$T/app-self" && "$AB" worktrees --dry-run)
want 'refuses the tree under the cursor' "skipped  $T/app-self [feat/self]  (you are standing in it — cd $O and run it again)" "$out"

echo
echo '--clean'
out=$(cd "$O" && "$AB" worktrees --clean); rc=$?
want 'removes worktree, branch and origin' "removed  $T/app-plain [feat/plain]  (worktree, branch feat/plain, origin/feat/plain)" "$out"
yes_ 'the tree is gone'                   '[ ! -d "$T/app-plain" ]'
yes_ 'the local branch is gone'           '! git -C "$O" rev-parse -q --verify feat/plain >/dev/null'
yes_ 'the remote branch is gone'          '! git -C "$O" ls-remote --exit-code --heads origin feat/plain >/dev/null'
want 'keeps the base of an open PR'       "removed  $T/app-stacked [feat/stacked]  (worktree, branch feat/stacked; origin/feat/stacked is left: open PR #9" "$out"
yes_ 'and it really is still on origin'   'git -C "$O" ls-remote --exit-code --heads origin feat/stacked >/dev/null'
want 'squash-merged goes with -D'         "removed  $T/app-squashed [feat/squashed]" "$out"
want 'a cache does not hold a tree back'  "removed  $T/app-cache [feat/cache]" "$out"
want 'my own tree goes'                   "removed  $T/app-self [feat/self]" "$out"
yes_ 'dirty work is untouched'            'grep -q more "$T/app-dirty/dirty.txt"'
yes_ 'untracked work is untouched'        '[ -f "$T/app-untracked/notes.txt" ]'
yes_ 'ignored data is untouched'          '[ -f "$T/app-data/local.db" ]'
yes_ 'the unmerged tree is untouched'     '[ -d "$T/app-open" ] && git -C "$O" rev-parse -q --verify feat/open >/dev/null'
yes_ 'the busy tree is untouched'         '[ -d "$T/app-busy" ]'
yes_ 'the other tool'"'"'s tree is untouched' '[ -d "$T/elsewhere/tree" ]'
yes_ 'exit 0 when nothing failed'         '[ "$rc" = 0 ]'
wantnot 'never --force'                   '--force' "$out"
out=$(cd "$O" && "$AB" worktrees --clean)
wantnot 'a second run has nothing to remove' 'removed' "$out"

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

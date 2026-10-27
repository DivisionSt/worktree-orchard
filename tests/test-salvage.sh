#!/usr/bin/env bash
#
# Regression harness for bin/worktree-orchard-salvage.
#
#   bash tests/test-salvage.sh bin/worktree-orchard-salvage
#
# WHY THIS EXISTS. The salvage step runs right before a worktree is deleted,
# by worktree-orchard rm and by any other tool's teardown that calls it. A miss
# is silent and permanent: the file it failed to copy is gone with the
# directory, and a wrong "safe" exit lets the caller delete a tree it should
# have kept. So this builds real repositories with a real bare remote and
# asserts on what lands in the main checkout and on the exit code that decides
# whether the tree survives.

set -uo pipefail

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    printf 'usage: %s <path-to-executable_wt-salvage>\n' "$0" >&2
    exit 2
fi
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")

# Resolved, because macOS's temp dir sits under the /var -> /private/var
# symlink and git reports the resolved path.
WORK=$(cd "$(mktemp -d)" && pwd -P) || exit 2
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name test
git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
# The keep list comes from the environment here, so no config file is read.
export ORCHARD_SALVAGE_KEEP="HANDOFF.md tmp"
unset ORCHARD_CONFIG

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in [$2]" ;; esac; }

# salvage DIR [ARGS...]: run it from DIR; output in $WORK/out and $WORK/err.
salvage() { local d=$1; shift; (cd "$d" && bash "$SRC" "$@") > "$WORK/out" 2> "$WORK/err"; }
saved() { ls -d "$M"/tmp/salvage/"$1"-* 2>/dev/null | head -1; }

# --- fixture: a remote, a main checkout, and one worktree per case ------------
git init -q --bare "$WORK/remote.git"
M="$WORK/proj"
git clone -q "$WORK/remote.git" "$M" 2>/dev/null
printf 't\n' > "$M/tracked.txt"
printf '.env\n.claude/settings.local.json\n/tmp/\nHANDOFF.md\n*.log\n' > "$M/.gitignore"
printf '.env\n.claude/settings.local.json\n' > "$M/.worktreeinclude"
git -C "$M" add -A && git -C "$M" commit -q -m init && git -C "$M" push -q origin main 2>/dev/null
printf 'KEY=main\n' > "$M/.env"

# tree NAME: a worktree on a pushed branch, with the .env wt new would copy in.
tree() {
  git -C "$M" worktree add -q -b "$1" "$WORK/$1" main 2>/dev/null
  git -C "$WORK/$1" push -q origin "$1" 2>/dev/null
  cp "$M/.env" "$WORK/$1/.env"
}

# === nothing at risk ==========================================================
tree clean
salvage "$WORK/clean" --block
check "a clean, pushed tree is safe to remove" "$?" 0
[ -z "$(saved clean)" ] && ok "and nothing is written for it" || bad "and nothing is written for it" "$(saved clean)"

salvage "$M" --block
check "the main working tree is never a candidate" "$?" 0
has "and says so" "$(cat "$WORK/err")" "main working tree"

# === gitignored files =========================================================
tree ign
printf 'handoff\n' > "$WORK/ign/HANDOFF.md"
mkdir -p "$WORK/ign/tmp/deep"; printf 'note\n' > "$WORK/ign/tmp/deep/note.md"
printf 'noise\n' > "$WORK/ign/build.log"
salvage "$WORK/ign" --block
check "gitignored files alone do not block removal" "$?" 0
d=$(saved ign)
[ -f "$d/files/HANDOFF.md" ] && ok "saves HANDOFF.md" || bad "saves HANDOFF.md" "$(ls -R "$d" 2>&1)"
[ -f "$d/files/tmp/deep/note.md" ] && ok "saves tmp/ with its paths" || bad "saves tmp/ with its paths" "$(ls -R "$d" 2>&1)"
[ ! -e "$d/files/build.log" ] && ok "skips an ignored file not on the list" || bad "skips an ignored file not on the list" "build.log saved"
[ ! -e "$d/files/.env" ] && ok "skips a .worktreeinclude file identical to main's" || bad "skips a .worktreeinclude file identical to main's" ".env saved"
git -C "$M" check-ignore -q "tmp/salvage/x" && ok "the salvage directory is ignored in main" || bad "the salvage directory is ignored in main" "not ignored"
[ -z "$(git -C "$M" status --porcelain)" ] && ok "main's git status stays clean" || bad "main's git status stays clean" "$(git -C "$M" status --porcelain)"
has "SALVAGE.txt says where it came from" "$(cat "$d/SALVAGE.txt")" "Salvaged from $WORK/ign"

tree envchg
printf 'KEY=changed\n' > "$WORK/envchg/.env"
salvage "$WORK/envchg"
check "saves a .worktreeinclude file that differs from main's" "$(cat "$(saved envchg)/files/.env" 2>&1)" "KEY=changed"

# === uncommitted work =========================================================
tree dirty
printf 'edited\n' > "$WORK/dirty/tracked.txt"
printf 'new\n' > "$WORK/dirty/fresh.txt"
salvage "$WORK/dirty" --block
check "--block refuses a tree with uncommitted changes" "$?" 1
has "and says why" "$(cat "$WORK/err")" "uncommitted change(s)"
d=$(saved dirty)
has "saves tracked changes as a patch" "$(cat "$d/changes.patch" 2>&1)" "+edited"
check "saves untracked files" "$(cat "$d/untracked/fresh.txt" 2>&1)" "new"
(cd "$M" && git apply --check "$d/changes.patch") && ok "the patch applies to main" || bad "the patch applies to main" "git apply --check failed"

salvage "$WORK/dirty"
check "without --block it saves and allows removal" "$?" 0

# === unpushed commits =========================================================
tree ahead
git -C "$WORK/ahead" commit -q --allow-empty -m "local only"
sha=$(git -C "$WORK/ahead" rev-parse HEAD)
salvage "$WORK/ahead" --block
check "--block refuses a tree with unpushed commits" "$?" 1
has "and says why" "$(cat "$WORK/err")" "1 unpushed commit(s)"
d=$(saved ahead)
pinned=$(git -C "$M" for-each-ref --format='%(objectname)' 'refs/salvage/ahead-*' | head -1)
check "pins HEAD under refs/salvage/ in the main repo" "$pinned" "$sha"
has "lists the unpushed commits" "$(cat "$d/unpushed.txt" 2>&1)" "local only"

# A detached HEAD whose commits no remote has is the case git cannot help with.
tree detached
git -C "$WORK/detached" switch -q --detach
git -C "$WORK/detached" commit -q --allow-empty -m "orphan"
salvage "$WORK/detached" --block
check "refuses a detached HEAD with unpushed commits" "$?" 1

# === --check ==================================================================
tree chk
printf 'edited\n' > "$WORK/chk/tracked.txt"
printf 'h\n' > "$WORK/chk/HANDOFF.md"
salvage "$WORK/chk" --check
check "--check reports unsafe work with exit 1" "$?" 1
has "and counts what it would save" "$(cat "$WORK/out")" "would save:  1 gitignored file(s)"
[ -z "$(saved chk)" ] && ok "--check writes nothing" || bad "--check writes nothing" "$(saved chk)"

# === a repo with no remote ====================================================
L="$WORK/local"
git init -q "$L"; printf 'x\n' > "$L/x"; git -C "$L" add x; git -C "$L" commit -q -m init
git -C "$L" worktree add -q -b lt "$WORK/lt" 2>/dev/null
git -C "$WORK/lt" commit -q --allow-empty -m more
salvage "$WORK/lt" --block
check "with no remote at all, commits are not called unpushed" "$?" 0
L2=$(ls -d "$L"/tmp/salvage/* 2>/dev/null | head -1)
[ -z "$L2" ] && ok "and nothing is written" || bad "and nothing is written" "$L2"

printf 'h\n' > "$WORK/lt/HANDOFF.md"
printf 'HANDOFF.md\n' > "$L/.gitignore"; git -C "$L" add .gitignore; git -C "$L" commit -q -m ign
git -C "$WORK/lt" merge -q main 2>/dev/null
salvage "$WORK/lt"
git -C "$L" check-ignore -q tmp/salvage/x && ok "excludes tmp/salvage/ where the repo does not ignore tmp/" || bad "excludes tmp/salvage/ where the repo does not ignore tmp/" "$(cat "$L/.git/info/exclude")"
[ -z "$(git -C "$L" status --porcelain)" ] && ok "so main stays clean there too" || bad "so main stays clean there too" "$(git -C "$L" status --porcelain)"

# === the keep list comes from configuration =================================
tree nokeep
printf 'handoff\n' > "$WORK/nokeep/HANDOFF.md"
(cd "$WORK/nokeep" && ORCHARD_SALVAGE_KEEP="" bash "$SRC" --check) > "$WORK/out" 2>&1
has "an empty keep list saves no HANDOFF.md" "$(cat "$WORK/out")" "nothing at risk"
mkdir -p "$WORK/cfg/worktree-orchard"
printf 'salvage_keep = HANDOFF.md\n' > "$WORK/cfg/worktree-orchard/config"
(cd "$WORK/nokeep" && env -u ORCHARD_SALVAGE_KEEP XDG_CONFIG_HOME="$WORK/cfg" bash "$SRC" --check) > "$WORK/out" 2>&1
has "salvage_keep is read from the config file" "$(cat "$WORK/out")" "would save:  1 gitignored file(s)"

# === usage ====================================================================
salvage "$WORK" --block
check "outside a repo is an error" "$?" 2
salvage "$WORK/clean" --bogus
check "an unknown option is a usage error" "$?" 2
salvage "$WORK/clean" --help
has "--help prints the header" "$(cat "$WORK/out")" "Exit codes: 0 safe to remove"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

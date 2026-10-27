#!/usr/bin/env bash
#
# Regression harness for bin/worktree-orchard.
#
#   bash tests/test-worktree-orchard.sh bin/worktree-orchard
#
# WHY THIS EXISTS. Every failure in the create and teardown path is quiet. A
# tree based on the wrong branch, a .env that was not copied, an agent started
# in the wrong directory or without its arguments, or a teardown that took a
# dirty tree each look like a working tree and a prompt. So this asserts on the
# tree, the copied files, and the exact tmux and agent command lines.
#
# ISOLATION. tmux, the agents and the shell are stand-ins on PATH that record
# their arguments, so almost all of the suite runs with no tmux server. The one
# exception is the session-join section, which needs real tmux behaviour: it
# starts a server on a private socket, never the default one, and skips where
# none can start. HOME is a scratch directory holding the config file. Fixture
# repos live under a temp dir.

set -uo pipefail

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    printf 'usage: %s <path-to-worktree-orchard>\n' "$0" >&2
    exit 2
fi
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")
SALV_SRC="$(dirname "$SRC")/worktree-orchard-salvage"
command -v git >/dev/null 2>&1 || { echo "test-worktree-orchard: git is required" >&2; exit 2; }

# Resolved, because macOS's temp dir sits under the /var -> /private/var
# symlink and git reports the resolved path.
WORK=$(cd "$(mktemp -d)" && pwd -P) || exit 2
trap 'rm -rf "$WORK"' EXIT
# The script under test is copied in under its real name, and with no salvage
# script beside it, so each test chooses its salvage explicitly.
mkdir -p "$WORK/app"
cp "$SRC" "$WORK/app/worktree-orchard"; chmod +x "$WORK/app/worktree-orchard"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in [$2]" ;; esac; }

# --- stand-ins ---------------------------------------------------------------
LOG="$WORK/log"; SESS="$WORK/sessions"
mkdir -p "$WORK/stub" "$WORK/home/.config/worktree-orchard"
cat > "$WORK/stub/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$ORCHARD_TEST_LOG"
case "$1" in
  has-session) grep -qxF "${3#=}" "$ORCHARD_TEST_SESS" 2>/dev/null ;;
  new-session) printf '%s\n' "$4" >> "$ORCHARD_TEST_SESS" ;;
  kill-session) grep -vxF "${3#=}" "$ORCHARD_TEST_SESS" > "$ORCHARD_TEST_SESS.new" 2>/dev/null; mv "$ORCHARD_TEST_SESS.new" "$ORCHARD_TEST_SESS" ;;
  list-sessions) exit 1 ;;
  *) exit 0 ;;
esac
STUB
for a in claude aider-run fakeagent fakeshell; do
  cat > "$WORK/stub/$a" <<STUB
#!/usr/bin/env bash
printf '$a pwd=%s args=%s\n' "\$PWD" "\$*" >> "\$ORCHARD_TEST_LOG"
STUB
done
chmod +x "$WORK/stub/"*
CONF="$WORK/home/.config/worktree-orchard/config"
cat > "$CONF" <<'CONF'
# A comment, and a blank line, both skipped.

agent.aider = aider-run
agent.fast = fakeagent --fast
alt_agent = aider
salvage_keep = HANDOFF.md tmp
hook.post_create = printf 'hook post_create %s %s %s\n' "$1" "$2" "$3" >> "$ORCHARD_TEST_LOG"
hook.post_remove = printf 'hook post_remove %s %s\n' "$1" "$3" >> "$ORCHARD_TEST_LOG"
CONF

export PATH="$WORK/stub:$PATH" HOME="$WORK/home" SHELL="$WORK/stub/fakeshell"
export ORCHARD_TEST_LOG="$LOG" ORCHARD_TEST_SESS="$SESS" ORCHARD_NO_HOLD=1 NO_COLOR=1
export ORCHARD_CODE_ROOT="$WORK/code"
unset TMUX ORCHARD_AGENT ORCHARD_WORK_DIR ORCHARD_PICKER_DRY_RUN ORCHARD_TMUX ORCHARD_CONFIG ORCHARD_NO_HOOKS ORCHARD_SALVAGE XDG_CONFIG_HOME SSH_CONNECTION SSH_TTY
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/gitconfig"
printf '[user]\n\temail = t@t\n\tname = t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

# Runs the script in $1 with the rest as args, in tmux mode unless TMUXMODE
# says otherwise. stdout and stderr land in $WORK/out and $WORK/err; returns
# its status.
run() {
  local dir=$1; shift
  : > "$LOG"
  (cd "$dir" && ORCHARD_TMUX="${TMUXMODE-always}" bash "$WORK/app/worktree-orchard" "$@") > "$WORK/out" 2> "$WORK/err" < "${STDIN_FILE:-/dev/null}"
}
# The same, for the self-dispatch calls the picker makes.
orch() { ORCHARD_TMUX=always bash "$WORK/app/worktree-orchard" "$@"; }
logged() { cat "$LOG"; }

# --- fixture: a repo whose main checkout sits on a feature branch ----------
R="$WORK/code/proj"
mkdir -p "$WORK/code"
git -C "$WORK/code" init -q proj
printf 'tracked\n' > "$R/tracked.txt"
printf '.env\n*.log\n.claude/settings.local.json\nsecret/\n/.claude/worktrees/\n' > "$R/.gitignore"
git -C "$R" add -A && git -C "$R" commit -q -m init
git -C "$R" update-ref refs/remotes/origin/main main
git -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
MAIN_SHA=$(git -C "$R" rev-parse --short main)
git -C "$R" switch -q -c some-feature
git -C "$R" commit -q --allow-empty -m "feature work"

# === new: the tree ========================================================
run "$R" new plain --none
check "new --none exits 0" "$?" 0
T="$R/.claude/worktrees/plain"
[ -d "$T" ] && ok "tree lands in .claude/worktrees/<name>" || bad "tree lands in .claude/worktrees/<name>" "no $T"
check "branch is worktree-<name>" "$(git -C "$T" branch --show-current)" worktree-plain
check "based on the default branch, not the main checkout's HEAD" "$(git -C "$T" rev-parse --short HEAD)" "$MAIN_SHA"
check "no upstream is configured" "$(git -C "$T" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo none)" none
grep -qxF "$T" "$R/.git/orchard-created" && ok "recorded in the orchard-created register" || bad "recorded in the orchard-created register" "$(cat "$R/.git/orchard-created" 2>&1)"
has "post_create hook gets the tree, the repo and the name" "$(logged)" "hook post_create $T $R plain"
has "says no .worktreeinclude means nothing copied" "$(cat "$WORK/err")" "no .worktreeinclude"
if grep -qE '^(tmux|claude|aider-run|fakeagent|fakeshell) ' "$LOG"; then bad "--none starts nothing" "$(logged)"; else ok "--none starts nothing"; fi

run "$R" new plain --none
[ "$?" != 0 ] && ok "refuses a name that already exists" || bad "refuses a name that already exists" "exit 0"
run "$R" new my.feature --none
[ "$?" != 0 ] && [ ! -e "$R/.claude/worktrees/my.feature" ] && ok "refuses a dot in the name" || bad "refuses a dot in the name" "$(cat "$WORK/err")"
run "$R" new
check "new with no name is a usage error" "$?" 2
run "$R" new x --bogus
check "unknown new option is a usage error" "$?" 2

# === new: .worktreeinclude ===============================================
printf '.env\n.claude/settings.local.json\nsecret/\nnotes.txt\ntracked.txt\n' > "$R/.worktreeinclude"
printf 'KEY=1\n' > "$R/.env"; chmod 600 "$R/.env"
mkdir -p "$R/.claude" "$R/secret/deep"
printf '{}\n' > "$R/.claude/settings.local.json"
printf 's\n' > "$R/secret/deep/key"
printf 'n\n' > "$R/notes.txt"          # matches the list, but git does not ignore it
printf 'l\n' > "$R/debug.log"          # ignored, but not on the list
printf 'other tree\n' > "$R/.claude/worktrees/plain/.env"   # inside another worktree
run "$R" new inc --none
I="$R/.claude/worktrees/inc"
[ -f "$I/.env" ] && ok "copies an ignored file on the list" || bad "copies an ignored file on the list" "no .env"
check "keeps the file mode" "$(stat -c %a "$I/.env" 2>/dev/null || stat -f %Lp "$I/.env")" 600
check "copied content is the main checkout's" "$(cat "$I/.env" 2>/dev/null)" "KEY=1"
[ -f "$I/.claude/settings.local.json" ] && ok "creates parent directories" || bad "creates parent directories" "no settings.local.json"
[ -f "$I/secret/deep/key" ] && ok "copies files under a listed directory" || bad "copies files under a listed directory" "no secret/deep/key"
[ ! -e "$I/notes.txt" ] && ok "skips an untracked file git does not ignore" || bad "skips an untracked file git does not ignore" "notes.txt copied"
check "leaves a tracked file as checked out" "$(cat "$I/tracked.txt")" tracked
[ ! -e "$I/debug.log" ] && ok "skips an ignored file not on the list" || bad "skips an ignored file not on the list" "debug.log copied"
[ ! -e "$I/.claude/worktrees" ] && ok "never copies out of another worktree" || bad "never copies out of another worktree" "$(find "$I/.claude" 2>&1)"
has "reports how many files were copied" "$(cat "$WORK/err")" "copied 3 gitignored file(s)"

# === new: starting the agent =============================================
run "$R" new a1
has "headless default starts claude in a named tmux session" "$(logged)" "tmux new-session -d -s proj_a1 -c $R/.claude/worktrees/a1 claude"
has "then attaches to it" "$(logged)" "tmux attach -t =proj_a1"

TMUX=fake run "$R" new a2
has "inside tmux it switches rather than attaches" "$(logged)" "tmux switch-client -t =proj_a2"

run "$R" new a3 --aider -- --preset go
has "--aider runs agent.aider and passes args" "$(logged)" "-c $R/.claude/worktrees/a3 aider-run --preset go"

run "$R" new a4 --shell
has "--shell lets tmux start the default shell" "$(logged)" "tmux new-session -d -s proj_a4 -c $R/.claude/worktrees/a4"
case "$(logged)" in *"proj_a4 -c $R/.claude/worktrees/a4 "*) bad "--shell passes no command" "$(logged)" ;; *) ok "--shell passes no command" ;; esac

ORCHARD_AGENT=aider run "$R" new a5
has "ORCHARD_AGENT=aider makes aider the default" "$(logged)" "aider-run"
ORCHARD_AGENT=bogus run "$R" new a6 --none
check "an undefined default agent is refused" "$?" 2
has "and the refusal names the key to set" "$(cat "$WORK/err")" "agent.bogus"

run "$R" new f1 --fast
has "--<name> works for any configured agent, with its own args first" "$(logged)" "-c $R/.claude/worktrees/f1 fakeagent --fast"
run "$R" new f2 --agent fast -- --extra
has "--agent NAME does the same and appends args after --" "$(logged)" "fakeagent --fast --extra"
run "$R" new f3 --agent nosuch
check "--agent with an undefined name is a usage error" "$?" 2
run "$R" new f4 --nosuch
check "--<name> with an undefined name is a usage error" "$?" 2

TMUXMODE=never run "$R" new w1 -- --model opus
has "tmux never execs claude in the tree, no tmux" "$(logged)" "claude pwd=$R/.claude/worktrees/w1 args=--model opus"
case "$(logged)" in *"tmux new"*) bad "tmux never starts no tmux session" "$(logged)" ;; *) ok "tmux never starts no tmux session" ;; esac
TMUXMODE=never run "$R" new w2 --tmux
has "--tmux forces a session when tmux is never" "$(logged)" "tmux new-session -d -s proj_w2"
run "$R" new h1 --no-tmux --aider
has "--no-tmux execs in place when tmux is always" "$(logged)" "aider-run pwd=$R/.claude/worktrees/h1"
SSH_CONNECTION="1 2 3 4" TMUXMODE=auto run "$R" new au1
has "tmux auto uses tmux inside an SSH session" "$(logged)" "tmux new-session -d -s proj_au1"
TMUXMODE=sometimes run "$R" new au2 --none
check "a bad tmux value is refused" "$?" 2

# Run from inside a worktree: the new tree still belongs to the main repo.
run "$R/.claude/worktrees/plain" new from-inside --none
[ -d "$R/.claude/worktrees/from-inside" ] && ok "new from inside a worktree targets the main repo" || bad "new from inside a worktree targets the main repo" "$(cat "$WORK/err")"

# === BY and NAME for every creating tool ====================================
git -C "$R" worktree add -q "$R/.claude/worktrees/by-claude" -b by-claude main 2>/dev/null
git -C "$R" worktree add -q "$R/.zed/worktrees/zz1/proj" -b by-zed main 2>/dev/null
mkdir -p "$WORK/home/.paseo/worktrees/abcd"
git -C "$R" worktree add -q "$WORK/home/.paseo/worktrees/abcd/pz" -b by-paseo main 2>/dev/null
mkdir -p "$WORK/home/emdash/worktrees/proj"
git -C "$R" worktree add -q "$WORK/home/emdash/worktrees/proj/em-task-x1" -b emdash/task main 2>/dev/null
git -C "$R" worktree add -q "$R/.emdash/worktrees/em2" -b emdash/two main 2>/dev/null
git -C "$R" worktree add -q "$WORK/elsewhere" -b by-git main 2>/dev/null
mkdir -p "$WORK/wd"
: > "$LOG"
(cd "$R" && ORCHARD_WORK_DIR="$WORK/wd" orch --trees --rows >/dev/null 2>&1)
by_of() { awk -v FS="$(printf '\037')" -v p="tree:$1" '$1 == p { print $3 "/" $7 }' "$WORK/wd/trees.tsv"; }
check "trees made here read as orchard"    "$(by_of "$R/.claude/worktrees/plain")" "plain/orchard"
check "claude --worktree trees read as claude" "$(by_of "$R/.claude/worktrees/by-claude")" "by-claude/claude"
check "Zed trees read as zed, named by their folder" "$(by_of "$R/.zed/worktrees/zz1/proj")" "zz1/zed"
check "Paseo trees read as paseo, named past the id" "$(by_of "$WORK/home/.paseo/worktrees/abcd/pz")" "pz/paseo"
check "emdash local-root trees read as emdash" "$(by_of "$WORK/home/emdash/worktrees/proj/em-task-x1")" "em-task-x1/emdash"
check "emdash in-repo trees read as emdash" "$(by_of "$R/.emdash/worktrees/em2")" "em2/emdash"
check "anything else reads as git"         "$(by_of "$WORK/elsewhere")" "elsewhere/git"
check "the main tree reads as -"           "$(by_of "$R")" "proj/-"

# === joining a session to its row, against a real tmux ======================
# The join trusts a <repo>_<name> session only if tmux says it sits in that
# tree. tmux 3.4 prints nothing for display-message -t '=name' (a pane target),
# which an earlier version read as "trust it", so a same-named session elsewhere
# joined the wrong row. Only a real tmux shows that, so this runs one on
# a private socket and skips where none can start, as inside the agent sandbox.
# Each session runs sleep, because SHELL here is a stand-in that exits at once,
# and a session whose only process exits takes the server down with it.
REAL_TMUX=$(PATH=$(printf '%s' "$PATH" | sed "s#$WORK/stub:##") command -v tmux || true)
RSOCK="$WORK/real.sock"
if [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$RSOCK" new-session -d -s probe sleep 600 2>/dev/null; then
  mkdir -p "$WORK/rtmux"
  printf '#!/usr/bin/env bash\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$RSOCK" > "$WORK/rtmux/tmux"; chmod +x "$WORK/rtmux/tmux"
  "$REAL_TMUX" -S "$RSOCK" new-session -d -s proj_plain -c "$WORK" sleep 600
  "$REAL_TMUX" -S "$RSOCK" new-session -d -s proj_inc -c "$R/.claude/worktrees/inc" sleep 600
  # The session this creates for the main tree is <repo>_<repo>, and a tool
  # that names its own sessions (emdash) matches no convention at all. Both
  # showed up twice, once as a tree and once as an orphan session.
  "$REAL_TMUX" -S "$RSOCK" new-session -d -s proj_proj -c "$R" sleep 600
  "$REAL_TMUX" -S "$RSOCK" new-session -d -s odd-emdash-name -c "$WORK/home/emdash/worktrees/proj/em-task-x1" sleep 600
  "$REAL_TMUX" -S "$RSOCK" new-session -d -s bare-in-by-git -c "$R/.claude/worktrees/by-claude" sleep 600
  # Sessions that belong to no tree of this repo. The default scope is the
  # current repo, so another repo's sessions must not be listed under it.
  mkdir -p "$WORK/code/other-repo" "$R/subdir"
  "$REAL_TMUX" -S "$RSOCK" new-session -d -s unrelated -c "$WORK/code/other-repo" sleep 600
  "$REAL_TMUX" -S "$RSOCK" new-session -d -s shell-in-subdir -c "$R/subdir" sleep 600
  mkdir -p "$WORK/home/emdash/worktrees/proj/not-a-tree"
  "$REAL_TMUX" -S "$RSOCK" new-session -d -s emdash-orphan-xyz -c "$WORK/home/emdash/worktrees/proj/not-a-tree" sleep 600
  rm -rf "$WORK/wd2" "$WORK/wd4"; mkdir -p "$WORK/wd2" "$WORK/wd4"
  (cd "$R" && PATH="$WORK/rtmux:$PATH" ORCHARD_WORK_DIR="$WORK/wd2" orch --rows >/dev/null 2>&1)
  (cd "$R" && PATH="$WORK/rtmux:$PATH" ORCHARD_WORK_DIR="$WORK/wd4" orch --all --rows >/dev/null 2>&1)
  row_of() { awk -v FS="$(printf '\037')" -v k="$1" '$1 == k { print $2 "|" $10 }' "$WORK/wd2/trees.tsv"; }
  check "a same-named session in another directory does not join" "$(row_of "tree:$R/.claude/worktrees/plain")" "○|"
  check "and it is listed as a session of its own" "$(row_of "sess:proj_plain")" "▸|proj_plain"
  check "a session sitting in its tree still joins" "$(row_of "tree:$R/.claude/worktrees/inc")" "●|proj_inc"
  check "the main tree joins the session new creates for it" "$(row_of "tree:$R")" "●|proj_proj"
  check "so that session is not listed a second time" "$(row_of "sess:proj_proj")" ""
  check "a session another tool named joins on its directory" "$(row_of "tree:$WORK/home/emdash/worktrees/proj/em-task-x1")" "●|odd-emdash-name"
  check "and is not listed a second time either" "$(row_of "sess:odd-emdash-name")" ""
  check "another repo's session is not listed in the default scope" "$(row_of "sess:unrelated")" ""
  check "a session in a subdirectory of the repo is" "$(row_of "sess:shell-in-subdir")" "▸|shell-in-subdir"
  check "a session beside the repo's trees but in none is not" "$(row_of "sess:emdash-orphan-xyz")" ""
  check "--all lists another repo's session" "$(awk -v FS="$(printf '\037')" '$1 == "sess:unrelated" { print $2 "|" $10 }' "$WORK/wd4/trees.tsv")" "▸|unrelated"
  check "a differently named session in a tree joins it too" "$(row_of "tree:$R/.claude/worktrees/by-claude")" "●|bare-in-by-git"
  "$REAL_TMUX" -S "$RSOCK" kill-server 2>/dev/null || true
else
  printf 'SKIP  session join against a real tmux: no tmux server could start here\n'
fi

# === row layout by width =====================================================
# The picker was unreadable at both ends. Narrow, the name and branch floors made
# every row wider than the pane, so fzf clipped it and AGE went first. Wide, the
# columns were fixed guesses rather than sized to what is in them. Narrow panes
# now get two lines per row, and wide ones size each column to its content.
# ${#x} counts bytes in a C locale, and the row glyphs are multibyte, so the
# width checks only run where a UTF-8 locale exists.
U8=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -1 || true)
run "$R" new long-descriptive-worktree-name-here --none
git -C "$R" worktree add -q "$WORK/home/emdash/worktrees/proj/emdash-fix-abc" -b emdash/fixabc main 2>/dev/null
mkdir -p "$WORK/wd3"
rows_at() { (cd "$R" && LC_ALL="${U8:-C}" ORCHARD_LIST_COLS=$1 ORCHARD_WORK_DIR="$WORK/wd3" orch --rows 2>/dev/null); }
# Prints what is wrong with the rows at width $1, or nothing. Shape $2 is
# "stacked" (two lines, NUL-ended) or "flat" (one line, newline-ended).
row_faults() {
  local w=$1 shape=$2 rec body l1 rest faults="" n=0
  if [ "$shape" = flat ]; then
    while IFS= read -r rec; do
      n=$((n+1)); body=${rec#*$'\t'}
      [ "${#body}" -le "$w" ] || faults="$faults [${#body} wide: $body]"
      case "$body" in *[0-9][mhd]|*-) ;; *) faults="$faults [no age: $body]" ;; esac
    done < <(rows_at "$w")
  else
    while IFS= read -r -d '' rec; do
      n=$((n+1)); body=${rec#*$'\t'}
      l1=${body%%$'\n'*}; rest=${body#*$'\n'}
      [ "$rest" != "$body" ] || { faults="$faults [one line: $body]"; continue; }
      case "$rest" in *$'\n'*) faults="$faults [three lines: $body]" ;; esac
      [ "${#l1}" -le "$w" ] || faults="$faults [line 1 ${#l1} wide: $l1]"
      [ "${#rest}" -le "$w" ] || faults="$faults [line 2 ${#rest} wide: $rest]"
      case "$l1" in *[0-9][mhd]|*-) ;; *) faults="$faults [no age: $l1]" ;; esac
    done < <(rows_at "$w")
  fi
  [ "$n" -ge 5 ] || faults="$faults [only $n rows]"
  printf '%s' "$faults"
}
if [ -n "$U8" ]; then
  check "a 41-column pane gets two-line rows that fit, age kept" "$(row_faults 41 stacked)" ""
  check "a 60-column pane does too" "$(row_faults 60 stacked)" ""
  check "an 80-column pane keeps one line per row, age kept" "$(row_faults 80 flat)" ""
  check "so does a 130-column pane" "$(row_faults 130 flat)" ""
  check "and a 200-column pane" "$(row_faults 200 flat)" ""
  # 72 is where a row can no longer hold a name worth reading; 71 must stack.
  check "a 71-column pane stacks" "$(row_faults 71 stacked)" ""
else
  printf 'SKIP  row widths: no UTF-8 locale here\n'
fi
# Only the shown text: field 1 of a row is its key, which holds the whole path.
shown_at() { rows_at "$1" | tr '\0' '\n' | awk -F'\t' '{ print $NF }'; }
case "$(shown_at 41)" in *"long-descriptive-worktree-name-here"*) bad "a narrow row clips a name that cannot fit" "full name shown" ;; *) ok "a narrow row clips a name that cannot fit" ;; esac
has "a wide pane shows a long name in full" "$(shown_at 140)" "long-descriptive-worktree-name-here "
has "narrow rows put git and who made it on a second line" "$(shown_at 41)" "clean  =  orchard"
case "$(shown_at 140)$(shown_at 41)" in *"worktree-inc"*) bad "no row shows a branch" "worktree-inc appears" ;; *) ok "no row shows a branch" ;; esac
has "the preview names the branch instead" "$(cd "$R" && ORCHARD_WORK_DIR="$WORK/wd3" orch --preview-row "tree:$R/.claude/worktrees/inc" 2>&1)" "branch: worktree-inc"
case "$(shown_at 140)" in *"emdash-fix-abc"*) bad "emdash's own name prefix is dropped from NAME" "still shown" ;; *"fix-abc"*) ok "emdash's own name prefix is dropped from NAME" ;; *) bad "emdash's own name prefix is dropped from NAME" "row missing" ;; esac
check "and the stored name is untouched, so rm still finds it" "$(awk -v FS="$(printf '\037')" -v p="tree:$WORK/home/emdash/worktrees/proj/emdash-fix-abc" '$1 == p { print $3 }' "$WORK/wd3/trees.tsv")" "emdash-fix-abc"

# === rm =====================================================================
printf 'y\n' > "$WORK/yes"
STDIN_FILE="$WORK/yes" run "$R" rm elsewhere
[ ! -e "$WORK/elsewhere" ] && ok "rm removes a tree any tool made, by name" || bad "rm removes a tree any tool made, by name" "$(cat "$WORK/err")"
git -C "$R" rev-parse --verify -q by-git >/dev/null && ok "rm keeps the branch" || bad "rm keeps the branch" "by-git is gone"
has "rm prints the branch delete command" "$(cat "$WORK/err")" "branch by-git is still there"

printf 'dirty\n' > "$R/.claude/worktrees/by-claude/tracked.txt"
STDIN_FILE="$WORK/yes" run "$R" rm by-claude
[ "$?" != 0 ] && [ -d "$R/.claude/worktrees/by-claude" ] && ok "rm refuses a dirty tree" || bad "rm refuses a dirty tree" "$(cat "$WORK/err")"
git -C "$R/.claude/worktrees/by-claude" checkout -q -- tracked.txt

printf 'n\n' > "$WORK/no"
STDIN_FILE="$WORK/no" run "$R" rm by-claude
[ -d "$R/.claude/worktrees/by-claude" ] && ok "rm does nothing unless confirmed" || bad "rm does nothing unless confirmed" "tree removed"

git -C "$R" worktree lock --reason "claude session 123" "$R/.claude/worktrees/by-claude"
STDIN_FILE="$WORK/yes" run "$R" rm by-claude
[ "$?" != 0 ] && [ -d "$R/.claude/worktrees/by-claude" ] && ok "rm refuses a locked tree" || bad "rm refuses a locked tree" "$(cat "$WORK/err")"
has "and names the -f way out" "$(cat "$WORK/err")" "worktree-orchard rm -f by-claude"
STDIN_FILE="$WORK/yes" run "$R" rm -f by-claude
[ ! -e "$R/.claude/worktrees/by-claude" ] && ok "rm -f unlocks and removes" || bad "rm -f unlocks and removes" "$(cat "$WORK/err")"

# === rm with salvage ==========================================================
# The real script beside the one under test, not a stand-in: what matters is
# the file landing in the main checkout and the tree surviving unpushed work.
SALV="$WORK/salvage-copy"
cp "$SALV_SRC" "$SALV" && chmod +x "$SALV"
printf 'HANDOFF.md\n/tmp/\n' >> "$R/.git/info/exclude"
run "$R" new sv --none
printf 'handoff\n' > "$R/.claude/worktrees/sv/HANDOFF.md"
ORCHARD_SALVAGE="$SALV" STDIN_FILE="$WORK/yes" run "$R" rm sv
[ ! -e "$R/.claude/worktrees/sv" ] && ok "rm with salvage still removes a safe tree" || bad "rm with salvage still removes a safe tree" "$(cat "$WORK/err")"
check "rm saves HANDOFF.md to the main checkout first" "$(cat "$R"/tmp/salvage/sv-*/files/HANDOFF.md 2>&1)" "handoff"
run "$R" new sv2 --none
git -C "$R/.claude/worktrees/sv2" commit -q --allow-empty -m "local only"
ORCHARD_SALVAGE="$SALV" STDIN_FILE="$WORK/yes" run "$R" rm sv2
[ "$?" != 0 ] && [ -d "$R/.claude/worktrees/sv2" ] && ok "rm refuses a tree with unpushed commits" || bad "rm refuses a tree with unpushed commits" "$(cat "$WORK/err")"
has "and says to push first" "$(cat "$WORK/err")" "Push it first"
ORCHARD_SALVAGE="$WORK/no-such-salvage" STDIN_FILE="$WORK/yes" run "$R" rm sv2
[ -d "$R/.claude/worktrees/sv2" ] && ok "a salvage that cannot run leaves the tree in place" || bad "a salvage that cannot run leaves the tree in place" "tree removed"
has "and says salvage failed, not that work is unpushed" "$(cat "$WORK/err")" "salvage failed"

printf 'proj_a1\n' >> "$SESS"
STDIN_FILE="$WORK/yes" run "$R" rm a1
has "rm kills the tree's tmux session" "$(logged)" "tmux kill-session -t =proj_a1"

run "$R" rm proj
[ "$?" != 0 ] && [ -d "$R" ] && ok "rm never targets the main tree" || bad "rm never targets the main tree" "$(cat "$WORK/err")"
run "$R" rm no-such-tree
[ "$?" != 0 ] && ok "rm on an unknown name fails" || bad "rm on an unknown name fails" "exit 0"
has "and says how to list trees" "$(cat "$WORK/err")" "worktree-orchard --trees"
run "$R" rm
check "rm with no name is a usage error" "$?" 2

# === the picker ==============================================================
ORCHARD_PICKER_DRY_RUN=1 run "$R" -i
args=$(grep -a '^fzf-args' "$WORK/out")
has "o opens with alt_agent" "$args" "o:execute-silent(printf '%s' 'aider' > "
has "/ frees o for typing" "$args" "unbind(j,k,g,G,s,o,"
has "the prompt names the command" "$args" "worktree-orchard both/repo> "
grep -v '^alt_agent' "$CONF" > "$WORK/conf-noalt"
ORCHARD_CONFIG="$WORK/conf-noalt" ORCHARD_PICKER_DRY_RUN=1 run "$R" -i
has "with no alt_agent, o is bound to ignore" "$(grep -a '^fzf-args' "$WORK/out")" "o:ignore"
ORCHARD_PICKER_DRY_RUN=1 run "$R" new nope --none
[ ! -e "$R/.claude/worktrees/nope" ] && ok "ORCHARD_PICKER_DRY_RUN blocks new" || bad "ORCHARD_PICKER_DRY_RUN blocks new" "tree created"
ORCHARD_PICKER_DRY_RUN=1 STDIN_FILE="$WORK/yes" run "$R" rm a2
[ -d "$R/.claude/worktrees/a2" ] && ok "ORCHARD_PICKER_DRY_RUN blocks rm" || bad "ORCHARD_PICKER_DRY_RUN blocks rm" "tree removed"

# === configuration ===========================================================
printf 'worktree_dir = .trees/\nbranch_prefix = wip/\nbogus_key = 1\nno equals sign here\n' > "$WORK/conf-layout"
git -C "$WORK/code" init -q layout
git -C "$WORK/code/layout" commit -q --allow-empty -m init
ORCHARD_CONFIG="$WORK/conf-layout" run "$WORK/code/layout" new lay --none
[ -d "$WORK/code/layout/.trees/lay" ] && ok "worktree_dir moves where trees land" || bad "worktree_dir moves where trees land" "$(cat "$WORK/err")"
check "branch_prefix names the branch" "$(git -C "$WORK/code/layout/.trees/lay" branch --show-current 2>&1)" "wip/lay"
grep -qxF '/.trees/' "$WORK/code/layout/.git/info/exclude" && ok "an unignored worktree_dir is added to info/exclude" || bad "an unignored worktree_dir is added to info/exclude" "$(cat "$WORK/code/layout/.git/info/exclude" 2>&1)"
check "so the main checkout stays clean" "$(git -C "$WORK/code/layout" status --porcelain)" ""
has "an unknown key is named" "$(cat "$WORK/err")" "unknown key 'bogus_key'"
has "a line with no = is named" "$(cat "$WORK/err")" "line 4 has no '='"
ORCHARD_CONFIG="$WORK/conf-layout" run "$WORK/code/layout" new lay2 --none
case "$(cat "$WORK/code/layout/.git/info/exclude")" in *"/.trees/"*"/.trees/"*) bad "the exclude line is added once" "added twice" ;; *) ok "the exclude line is added once" ;; esac
mkdir -p "$WORK/wd5"
(cd "$WORK/code/layout" && ORCHARD_CONFIG="$WORK/conf-layout" ORCHARD_WORK_DIR="$WORK/wd5" orch --trees --rows >/dev/null 2>&1)
check "a tree in a custom worktree_dir is named and read as orchard" "$(awk -v FS="$(printf '\037')" -v p="tree:$WORK/code/layout/.trees/lay" '$1 == p { print $3 "/" $7 }' "$WORK/wd5/trees.tsv")" "lay/orchard"

printf 'creator.scratch = %s/scratch-*\n' "$WORK" > "$WORK/conf-creator"
git -C "$R" worktree add -q "$WORK/scratch-one" -b scratch-one main 2>/dev/null
mkdir -p "$WORK/wd6"
(cd "$R" && ORCHARD_CONFIG="$WORK/conf-creator" ORCHARD_WORK_DIR="$WORK/wd6" orch --trees --rows >/dev/null 2>&1)
check "a creator.<label> glob labels a tree" "$(awk -v FS="$(printf '\037')" -v p="tree:$WORK/scratch-one" '$1 == p { print $7 }' "$WORK/wd6/trees.tsv")" "scratch"

# post_remove gets the removed tree's path, and ORCHARD_NO_HOOKS silences both.
STDIN_FILE="$WORK/yes" run "$R" rm scratch-one
has "post_remove hook runs after a removal" "$(logged)" "hook post_remove $WORK/scratch-one scratch-one"
ORCHARD_NO_HOOKS=1 run "$R" new quiet --none
case "$(logged)" in *"hook "*) bad "ORCHARD_NO_HOOKS runs no hook" "$(logged)" ;; *) ok "ORCHARD_NO_HOOKS runs no hook" ;; esac
printf 'hook.post_create = exit 3\n' > "$WORK/conf-failhook"
ORCHARD_CONFIG="$WORK/conf-failhook" run "$R" new hookfail --none
check "a failing hook does not fail the create" "$?" 0
has "but it is reported" "$(cat "$WORK/err")" "hook.post_create exited 3"

# === invoked under another name, and the salvage subcommand ===================
# A symlink named wt is how most people will shorten it. Messages follow the
# name it was run as, and the salvage script is found beside the real file.
mkdir -p "$WORK/link"
cp "$SALV_SRC" "$WORK/app/worktree-orchard-salvage"; chmod +x "$WORK/app/worktree-orchard-salvage"
ln -s "$WORK/app/worktree-orchard" "$WORK/link/wt"
(cd "$R" && ORCHARD_TMUX=always "$WORK/link/wt" rm no-such-tree) > "$WORK/out" 2> "$WORK/err"
has "messages use the name it was run as" "$(cat "$WORK/err")" "\`wt --trees\` lists them"
(cd "$R/.claude/worktrees/plain" && "$WORK/link/wt" salvage --check) > "$WORK/out" 2> "$WORK/err"
check "salvage runs the sibling script through a symlink" "$?" 0
has "and reports on the tree" "$(cat "$WORK/out")" "would save:  1 gitignored file(s)"
rm -f "$WORK/app/worktree-orchard-salvage"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

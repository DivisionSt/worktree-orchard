# worktree-orchard

One numbered list of the git worktrees and tmux sessions you can get back into, with one way to create them and one way to tear them down safely.

```
 #   S    NAME         GIT     SYNC   BY      AGE
 1 * ⌂    webapp       clean   =      -       2d
 2   ●    login-fix    clean   ↑1     orchard 40m
 3   ○    search-api   +1      =      orchard 3h
 4   ▸    scratch      -       -      -       1d
```

It was built for running several coding agents at once (Claude Code, or anything else you start from a shell), each in its own worktree and often in its own tmux session, but nothing in it depends on agents. If you use worktrees and tmux together, it is for you.

## What problem does this solve?

A worktree and the tmux session you work in are usually the same thing seen twice. `git worktree list` shows the checkouts, `tmux ls` shows the sessions, and the question you actually have, "what can I get back into, and what state is it in?", is in neither list. worktree-orchard joins the two into one row per workspace, shows the git state beside it, and gives every row a number you can open with one keystroke.

It also does not care who made a worktree. Paths come from `git worktree list`, so trees made by Claude Code, Zed's agent panel, emdash, Paseo, plain `git worktree add`, or this tool all appear, are labelled by who made them, and tear down the same way.

## What do I need?

| Requirement | Why |
|---|---|
| bash 3.2 or newer | The stock macOS bash works. |
| git 2.31 or newer | For `rev-parse --path-format=absolute`. |
| tmux | For session rows and tmux mode. Without tmux running, you still get the worktree rows. |
| fzf 0.45 or newer | Only for the interactive picker (`-i`). Ubuntu's apt package is 0.44, so install fzf from its GitHub releases or Homebrew there. |

It runs on macOS and Linux. CI runs the test suite on both, and on macOS's bash 3.2.

## How do I install it?

```bash
git clone https://github.com/DivisionSt/worktree-orchard.git
cd worktree-orchard
make install                 # symlinks into ~/.local/bin
make install PREFIX=/usr/local   # or anywhere else
```

`make install` symlinks both `worktree-orchard` and `worktree-orchard-salvage` into `$PREFIX/bin`, so a `git pull` in the clone updates the installed copy. The name is long on purpose, to avoid colliding with other tools; give it whatever short name you like:

```bash
alias wt=worktree-orchard          # in your shell rc
# or, so scripts and other tools can call it by the short name too:
ln -s ~/.local/bin/worktree-orchard ~/.local/bin/wt
```

Messages and the help text follow the name you run it as, so a symlink called `wt` reads as `wt` everywhere.

## How do I use it day to day?

```bash
worktree-orchard                 # print the table for the repo you are in
worktree-orchard -i              # open the picker
worktree-orchard 3               # open row 3 straight from the shell
worktree-orchard new login-fix   # new worktree, with your default agent started in it
worktree-orchard rm login-fix    # tear it down safely
```

Opening a row attaches to its tmux session if one is running. If none is, it creates one and starts your default agent in the tree, or, outside tmux mode, changes into the tree and runs the agent directly. See "When does it use tmux?" below.

### The four ways to run it

| Command | What happens |
|---|---|
| `worktree-orchard` | Print the table and exit. This is how you learn the row numbers. |
| `worktree-orchard -i` | Interactive picker. A digit key moves to that row; `enter` opens it. |
| `worktree-orchard -ia` | The same picker, but a digit key opens its row outright, in one keystroke. |
| `worktree-orchard 3` | Open row 3 with no picker. |

Rows are numbered 1 to 9 and then 0 for the tenth, the way a browser numbers its tabs, so the ten digit keys cover exactly the first ten rows. Nothing is ever labelled 10. The number is the row's position in the list as printed, so it moves when you change the filter or the scope: run the bare command first, read the number, then use it.

### Scope and filter flags

| Flag | Effect |
|---|---|
| `-a`, `--all` | Every repo one level under your code root (default `~/code`), not just the current one. |
| `--trees` | Worktrees only. |
| `--tmux` | tmux sessions only. |
| `--no-color` | No colour. `NO_COLOR` does the same. |
| `-h`, `--help` | The full help text. |

Without `--all`, sessions are limited to the current repo too: a session counts as this repo's when it sits in the main checkout or any of its worktrees, or is named for the repo.

### Making and removing trees

| Command | What happens |
|---|---|
| `new <name>` | A new tree at `.claude/worktrees/<name>` on branch `worktree-<name>`, based on the repo's default branch, with the gitignored files listed in `.worktreeinclude` copied in. Then your default agent starts there. |
| `new <name> --agent NAME` | The same, starting a different agent. `--NAME` is shorthand for any agent you defined, so `--claude` and `--shell` always work. |
| `new <name> --none` | Stop at the tree; start nothing. |
| `new <name> -- --model opus` | Anything after `--` is passed to the agent. |
| `new <name> --tmux` or `--no-tmux` | Force the tmux session on or off for this one tree. |
| `rm <name>` | Tear down this repo's tree called `<name>`, whichever tool made it. Same safety checks as the picker's `x` key. |
| `rm -f <name>` | Lift a worktree lock first. Claude Code locks a tree for the life of its session. |
| `salvage [--check \| --block] [<tree>]` | Run the salvage step on its own. See "What happens to my work when a tree is removed?" |

Names take letters, digits, `_` and `-` only. A dot is refused because tmux reads `.` as the pane separator in `session:window.pane`, so a tree called `my.feature` would get a session it could never rejoin.

New trees are based on the repo's default branch (whatever `origin/HEAD` points at, as a local branch), not on whatever the main checkout happens to have checked out, and the base is printed when the tree is made. They are created with `--no-track`, so they have no upstream until you push them.

If the worktree directory sits inside your checkout and the repo does not already ignore it, `new` adds it to `.git/info/exclude`, the repo's local, uncommitted ignore file, and says so. Otherwise every new tree would show up as untracked in the main checkout.

## How does the picker work?

The picker is modal, the way vi is. Single keys act, and typing only filters once you ask for it with `/`. Press `?` at any time for the key map.

| Key | Action |
|---|---|
| `1`-`9`, `0` | Go to that numbered row. Under `-ia` it opens the row too. |
| `enter` | Open with your default agent, or attach if a session is live. |
| `o` | Open with your `alt_agent`, when you have set one. |
| `s` | Open with a plain shell. |
| `j` `k`, `g` `G`, `ctrl-d` `ctrl-u` | Down and up, first and last, half a page. |
| `/` | Start filtering. Every action key becomes a typed character. |
| `esc` | Stop filtering. When you are not filtering, it quits. |
| `n` | New worktree plus a tmux session running a shell. |
| `t` | New worktree and nothing else. |
| `x` | Tear down. Confirms first, refuses a dirty tree, never deletes the branch. |
| `r` | Rename the highlighted tmux session. |
| `f` | Cycle the filter: everything, sessions only, trees only. |
| `a` | Toggle between this repo and every repo. |
| `p` | Show or hide the preview pane. |
| `q` | Quit. |

The preview pane shows the tree's path and branch, any `salvage_keep` files parked in it, whatever your `preview` hook prints, the git status, and the last five commits. On a wide terminal it docks beside the list; on a narrow one it goes underneath, and each row takes two lines rather than clipping the name.

## How do I read the table?

| Column | Meaning |
|---|---|
| `#` | The row number. |
| `S` | `●` worktree and session both live. `○` worktree with no session. `▸` session with no worktree. `⌂` the repo's main checkout. |
| `*` | The worktree this shell is standing in. |
| `REPO` | Which repo the row belongs to. Shown only under `--all`. |
| `NAME` | The worktree's name, or the session's name for a `▸` row. |
| `GIT` | The count of uncommitted paths, or `clean`. `MISSING` means git still lists the worktree but the directory is gone. `UNKNOWN` means `git status` failed there. Teardown refuses both. |
| `SYNC` | Ahead and behind the upstream branch, or the repo's default branch when there is no upstream, which is the usual case for a fresh tree. `=` means level. |
| `BY` | Who made the worktree: `orchard`, `claude`, `zed`, `paseo`, `emdash`, `git`, or a label you defined. |
| `AGE` | Since the session started, or since the worktree directory last changed. Not creation time. |

There is no branch column: on nearly every row it repeated the name, so the preview pane shows the branch instead. emdash's own `emdash-` folder prefix is dropped from `NAME`, since `BY` already says emdash.

A session joins a tree's row when it is named `<repo>_<name>` and actually sits in that tree, or, failing that, when any session sits exactly in the tree's directory. That second rule is what lets tools that name their own sessions still show as one row per workspace.

## When does it use tmux?

The `tmux` setting decides whether opening a tree wraps the agent in a tmux session:

| Value | Behaviour |
|---|---|
| `auto` (default) | tmux when you are in an SSH session, or on Linux with no graphical display. Otherwise none. |
| `always` | Every open goes through a tmux session named `<repo>_<name>`. |
| `never` | Change into the tree and run the agent directly in this terminal. |

The reasoning behind `auto`: on a machine you reach over SSH, a dropped connection must not take the work with it, so the agent gets a session that outlives the connection. At a desktop, a tmux layer earns nothing and costs a prefix key. When you are already inside tmux, opening a row switches your client to the session rather than nesting a second tmux.

## What happens to my work when a tree is removed?

Removing a worktree deletes three kinds of work that exist nowhere else: uncommitted changes, commits no remote has, and gitignored files. `rm` and the `x` key protect each one, in this order:

1. A tree with uncommitted changes is refused. Commit or discard first.
2. A locked tree is refused, with the `rm -f` command to unlock it.
3. A tree with commits no remote has is refused. Push first.
4. You confirm.
5. The salvage step copies gitignored files worth keeping into the main checkout's `tmp/salvage/<tree>-<time>/`. Those are the paths in your `salvage_keep` setting, plus any `.worktreeinclude` file whose copy in the tree differs from the main checkout's. Each salvage folder has a `SALVAGE.txt` that says how to restore what it holds.
6. git removes the tree, then its tmux session is killed, then your `post_remove` hook runs. Removal comes first because it is the step that can fail; the other two cannot be undone.

The branch is never deleted. The `git branch -d` command is printed for you to run once you are sure it merged.

The salvage step is a separate script, `worktree-orchard-salvage`, so other tools can run it before they delete a tree. Run with `--block`, it saves what it can and then exits 1 when the tree holds uncommitted or unpushed work, which tells a caller that honours exit codes (Paseo's worktree teardown, for one) to keep the directory. Run with no flag, it saves and always exits 0, for tools that delete the tree whatever teardown returns. `--check` reports and writes nothing. When it does pin unpushed commits, it pins them under `refs/salvage/` in the main repository so garbage collection cannot take them.

Set `salvage = off` to skip it. Teardown then falls back to warning you about gitignored files before it confirms.

## How do gitignored files get into a new tree?

List them in a `.worktreeinclude` file at the repo root, in `.gitignore` syntax. This is the same file and the same rule Claude Code's `claude --worktree` uses:

```gitignore
.env
.env.local
.claude/settings.local.json
config/secrets/
```

A file is copied only when it matches a pattern there and git ignores it, so tracked files, and untracked files git does not ignore, are never duplicated. With no `.worktreeinclude`, nothing is copied and `new` says so.

## How do I configure it?

Settings live in `~/.config/worktree-orchard/config` (or `$XDG_CONFIG_HOME/worktree-orchard/config`, or wherever `ORCHARD_CONFIG` points). The file is `key = value` lines, with `#` comments. It is parsed, never sourced, so reading it cannot run code. A key it does not know, or a line with no `=`, is reported rather than silently ignored. Flags beat environment variables, which beat the file, which beats the defaults.

A complete example is in [`examples/config`](examples/config).

| Key | Default | What it does |
|---|---|---|
| `code_root` | `~/code` | Where `--all` looks for repos, one level deep. |
| `worktree_dir` | `.claude/worktrees` | Where `new` puts trees, relative to the repo's main checkout. The default matches `claude --worktree`, so trees from either tool sit side by side. |
| `branch_prefix` | `worktree-` | Prefix for the branch `new` creates. |
| `default_agent` | `claude` | What `enter`, a row number and `new` start. |
| `alt_agent` | none | What the `o` key starts. |
| `agent.<name>` | `agent.claude = claude` | Defines an agent. The value is a command, split on spaces; anything that needs quoting belongs in a small script the value points at. `shell` is always defined and means your login shell. |
| `tmux` | `auto` | `auto`, `always` or `never`. See "When does it use tmux?" |
| `salvage` | `on` | `off` skips the salvage step on teardown. |
| `salvage_keep` | none | Space-separated gitignored paths, relative to a tree's root, that the salvage step saves and the preview flags. For example `HANDOFF.md tmp`. |
| `creator.<label>` | none | A glob over a worktree's absolute path. A tree whose path matches shows `<label>` in the `BY` column. Checked in file order, before the built-in rules. A leading `~/` is expanded. |
| `hook.<name>` | none | A command to run at a point in a tree's life. See the next section. |

```ini
default_agent = claude
alt_agent = aider
agent.aider = aider --model sonnet
agent.claude = claude --permission-mode plan
tmux = always
salvage_keep = HANDOFF.md tmp
creator.conductor = ~/conductor/workspaces/*
```

## How do hooks work?

A hook is a shell command in the config file. It runs with `sh -c`, so it can hold a pipe, and its arguments arrive as `$1`, `$2` and so on. A hook that fails is reported and otherwise ignored: it never stops a tree being made or removed. Set `ORCHARD_NO_HOOKS=1` to run none of them.

| Hook | When | Arguments |
|---|---|---|
| `hook.post_create` | After `new`, `n` or `t` makes a tree and copies its files in. | `$1` the tree, `$2` the repo's main checkout, `$3` the name |
| `hook.post_remove` | After git removes a tree (or prunes a missing one), before the branch hint. | `$1` the tree's path, symlinks resolved, `$2` the main checkout, `$3` the name |
| `hook.picker_start` | Once, in the background, as the picker opens. Output is discarded. | `$1` a cache directory shared with `preview` |
| `hook.preview` | Every time the picker draws a preview. Its output is shown under the branch. | `$1` the tree or session directory, `$2` the preview width, `$3` the cache directory |

`preview` runs on every cursor move, so it has to be fast. Put anything slow in `picker_start`, have it write its results into the cache directory, and have `preview` read them. Write atomically (to a temporary name, then `mv` into place), because a preview can read the directory at any moment, and treat a missing file as "not ready yet".

Two examples:

```ini
# Tell another tool about every new tree.
hook.post_create = my-workspace-tool register "$1"

# Show the newest commit message from main beside each preview, cached once.
hook.picker_start = git -C ~/code/webapp log -1 --format=%s main > "$1/main.part" && mv "$1/main.part" "$1/main"
hook.preview = [ -f "$3/main" ] && printf 'main is at: %s\n' "$(cat "$3/main")"
```

## Which environment variables does it read?

| Variable | Effect |
|---|---|
| `ORCHARD_CONFIG` | Use this config file instead of the default. |
| `ORCHARD_AGENT` | The default agent, over `default_agent`. |
| `ORCHARD_TMUX` | `auto`, `always` or `never`, over `tmux`. |
| `ORCHARD_CODE_ROOT` | Where `--all` looks, over `code_root`. |
| `ORCHARD_PREVIEW_MIN_COLS` | The narrowest preview worth docking beside the list. Default 50. |
| `ORCHARD_STACK_BELOW` | The width below which each row takes two lines. Default 72. |
| `ORCHARD_NO_HOOKS` | Run none of the configured hooks. |
| `ORCHARD_NO_HOLD` | Do not wait for `enter` after an action in the picker. By default an action's output stays on screen until you press `enter`, because the list reloads straight after and would wipe it. |
| `ORCHARD_PICKER_DRY_RUN` | Print the fzf command and rows instead of running the picker, and refuse every action that would change anything. |
| `NO_COLOR` | No colour. |

## What are the things worth knowing before they bite?

- A worktree's `BY` label is `orchard` because `new` records every tree it makes in `.git/orchard-created`. Trees in `.claude/worktrees` that it did not make, such as ones from `claude --worktree` itself or from before you installed it, read as `claude`.
- `zed` and `emdash` rows can disappear on their own: Zed may remove a tree it made when its thread closes, and emdash when its task is deleted. Nothing else removes a row but you.
- A digit past the end of the list lands on the last row, not on nothing.
- `AGE` moves whenever the tree is written to, so an old tree you just edited reads as young.
- Claude Code locks a tree it made for the life of the session. `rm` refuses a locked tree and tells you about `rm -f`. Check the `S` column first: `●` means a session is live there.

## Does it pair with anything?

[cmux-berth](https://github.com/DivisionSt/cmux-berth) opens the tmux sessions this tool creates on a remote machine as rows in the cmux sidebar on a Mac, grouped by repo. It relies on the same `<repo>_<worktree>` session naming, and it works on its own with any sessions named that way.

## How do I work on it?

```bash
make test    # both test suites
make lint    # shellcheck at warning level
```

The tests replace tmux, the agents and the shell with stand-ins that record their arguments, so almost the whole suite runs anywhere, including CI runners and sandboxes. One section needs real tmux behaviour: it starts a server on a private socket, never your default one, and skips itself where none can start. Behaviour changes and test changes go together; the comments in the script say why each odd-looking choice was made, and most of them record a bug that the obvious version had.

## License

[MIT](LICENSE).

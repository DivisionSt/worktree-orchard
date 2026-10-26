# worktree-orchard

Two bash scripts in `bin/`: `worktree-orchard` (the list, picker, `new` and `rm`) and `worktree-orchard-salvage` (the save-before-delete step). The README is the user documentation and must stay true to the code.

## Checks

```bash
make test
make lint
```

Run both before every commit. The session-join section of the test suite needs a real tmux server on a private socket; inside a sandbox that blocks sockets it prints SKIP, so run it outside the sandbox before calling a change done.

## Rules

- Behaviour is pinned by `tests/`; change a behaviour and its test together. Never weaken a test to make it pass.
- Keep it bash 3.2 compatible: no associative arrays, `mapfile`, `${var,,}` or `local -n`. CI runs the suite under macOS's `/bin/bash`.
- The comments record why each odd-looking choice was made, usually a bug the obvious version had. Keep that density when you change code.
- The config file is parsed, never sourced. Keep it that way.

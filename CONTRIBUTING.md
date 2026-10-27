# Contributing

## What should I expect?

I built worktree-orchard for my own daily use and published it in case it helps someone else. Issues and pull requests are welcome, and I read all of them, but replies are best effort and I may decline a change that does not fit how I use the tool.

## How do I make a change?

1. Open an issue first for anything bigger than a small fix, so we can agree on the shape before you write it.
2. Change the behaviour and its test together. The tests in `tests/` pin what the tool does.
3. Run `make test` and `make lint` (shellcheck at warning level). Both must pass.
4. Keep it working on macOS's `/bin/bash`, which is bash 3.2: no associative arrays, `mapfile`, `${var,,}` or `local -n`. CI runs the suite under it.
5. Keep each pull request to one change, and say in it why the change is needed.

## How are versions numbered?

[Semantic versioning](https://semver.org). See the README's section on versions for what counts as a breaking change.

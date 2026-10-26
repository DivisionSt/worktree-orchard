PREFIX ?= $(HOME)/.local
BINS := worktree-orchard worktree-orchard-salvage

.PHONY: test lint install uninstall

test:
	bash tests/test-worktree-orchard.sh bin/worktree-orchard
	bash tests/test-salvage.sh bin/worktree-orchard-salvage

lint:
	shellcheck -S warning bin/* tests/*.sh

# Symlinks, so a git pull in this clone updates the installed copy.
install:
	mkdir -p "$(PREFIX)/bin"
	for b in $(BINS); do ln -sfn "$(CURDIR)/bin/$$b" "$(PREFIX)/bin/$$b"; done

uninstall:
	for b in $(BINS); do rm -f "$(PREFIX)/bin/$$b"; done

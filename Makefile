# ArcClone build entry points. Run `make` for a dev build, `make app` for a packaged .app,
# `make dmg` for a distributable disk image.
.PHONY: all core run test check lint hooks perf test-core selftest app dmg clean

all: core

core:
	cd core && swift build

run: all
	ARCCLONE_ROOT=$(CURDIR) core/.build/debug/ArcClone

test: check selftest

# Every automated test; CI runs this, so it lists whatever test suites the repo has.
check: lint test-core

# Static security checks (CLAUDE.md rules): banned APIs, log privacy, script guardrails, secrets.
lint:
	./scripts/security-lint.sh

# The PR performance gate (CLAUDE.md): 5,000+ tabs' memory and search speed, tab virtualization.
perf:
	cd core && swift test --filter "TabManagerPerformanceTests|TabVirtualizationTests|TabSleeperSchedulingTests"

# Runs the lint before every commit in this clone.
hooks:
	git config core.hooksPath .githooks

test-core:
	cd core && swift test

# Boots the real app headlessly-ish, exercises IPC/injections/assistant, exits with status.
selftest: all
	ARCCLONE_ROOT=$(CURDIR) perl -e 'alarm 90; exec @ARGV' core/.build/debug/ArcClone --self-test

app:
	./scripts/bundle.sh

dmg: app
	./scripts/make-dmg.sh

clean:
	rm -rf core/.build build

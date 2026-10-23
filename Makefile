# ArcClone build entry points. Run `make` for a dev build, `make app` for a packaged .app,
# `make dmg` for a distributable disk image.
.PHONY: all ui core run test check test-core test-ui selftest app dmg clean

all: core

core:
	cd core && swift build

run: all
	ARCCLONE_ROOT=$(CURDIR) core/.build/debug/ArcClone

test: check selftest

# Every automated test; CI runs this, so it lists whatever test suites the repo has.
check: test-ui test-core

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

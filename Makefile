# ArcClone build entry points. Run `make` for a dev build, `make app` for a packaged .app.
.PHONY: all ui core run test test-core test-bridge test-ui selftest app clean

all: ui core

ui/node_modules: ui/package.json
	cd ui && npm install --no-fund --no-audit
	@touch ui/node_modules

ui: ui/node_modules
	cd ui && npm run build

core:
	cd core && swift build

run: all
	ARCCLONE_ROOT=$(CURDIR) core/.build/debug/ArcClone

test: test-bridge test-ui test-core selftest

test-core:
	cd core && swift test

test-bridge:
	cd agent-bridge && npm test

test-ui: ui/node_modules
	cd ui && npm test

# Boots the real app headlessly-ish, exercises IPC/injections/agent bridge, exits with status.
selftest: all
	ARCCLONE_ROOT=$(CURDIR) perl -e 'alarm 90; exec @ARGV' core/.build/debug/ArcClone --self-test

app: ui
	./scripts/bundle.sh

clean:
	rm -rf core/.build ui/dist build

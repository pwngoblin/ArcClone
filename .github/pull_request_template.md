<!-- Title: conventional commit style, e.g. "feat(core): split view". Target: main (or see CONTRIBUTING.md). -->

## Summary
<!-- What changes and why. Link issues/PRs. If this PR is stacked, say "Stacked on #N". -->

## Security impact
<!-- Entitlements, IPC routes, storage, network, signing. Write "None" if not applicable. -->

## Test plan
- [ ] `make check` (security lint + Swift tests)
- [ ] `make selftest` prints `"result":"pass"`
- [ ] `make perf` (if this touches tabs, the sidebar or memory)
- [ ] `make app` (runs `scripts/verify-app.sh`)
- [ ] Manual checks:

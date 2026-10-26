# Contributing

## Branches

| Branch | Purpose | Receives changes from | Who merges |
|---|---|---|---|
| `main` | Source of truth; always builds, tests and passes the security audit | feature branches via PR | maintainer, after **CI / test** passes |
| `testing` | Pre-release builds (`vX.Y.Z-testing.N`) | **only** `main` | maintainer |
| `release` | Public releases (`vX.Y.Z`) | `main`, or `hotfix/*` for urgent fixes | maintainer |

Work happens on short-lived branches cut from `main`:

| Prefix | Use for |
|---|---|
| `feature/…` | new functionality |
| `fix/…` | bug or security fixes |
| `chore/…`, `docs/…`, `ci/…`, `refactor/…` | everything else |
| `hotfix/…` | urgent fix that must ship before `main` is ready; cut from `release`, PR into `release` **and** `main` |

Never commit directly to `main`, `testing` or `release`, and never merge `release` or `testing` back into `main`: changes only flow *out* of `main`.

## Pull requests

1. Branch from an up-to-date `main`. Use conventional, atomic commits (`feat(core): …`, `fix(ci): …`), each building on its own.
2. Push with upstream tracking and open a PR into `main` using the template. Describe security impact explicitly.
3. **CI / test** must pass. It runs the UI and Swift tests, packages the app, runs `scripts/verify-app.sh` and the packaged `--self-test`.
4. **Approval.** The *main: reviewed PRs only* ruleset needs an approving review from the code owner (`.github/CODEOWNERS`) on the latest push, all review threads resolved, and the branch up to date with `main` (**Update branch**). Nobody can push to `main` directly, force-push it or delete it; the maintainer's own PRs merge through the ruleset's PR-only bypass.
5. Merge with **Create a merge commit** (the only method enabled). Squash and rebase are disabled so atomic commits survive and stacked PRs stay mergeable.
6. GitHub deletes the head branch on merge. Delete your local copy: `git fetch --prune && git branch -d <branch>`.

### Stacked PRs

When one change builds on another, open PR B with PR A's branch as its base and write "Stacked on #A".

- Merge **bottom-up**: A into `main` first. GitHub then deletes A's branch and retargets B to `main` automatically.
- After a retarget, CI starts on its own. If a PR ever shows *blocked* with no checks, press **Update branch** on the PR (or `gh pr update-branch <n>`) to start them.
- Never merge B into A's branch after A has merged: B's changes would land on a dead branch and never reach `main` (this happened with #10; #13 re-landed it).

## Releases

| To publish | Do this |
|---|---|
| a test build | Open a PR `main → testing`. The run attaches a DMG. Merge it to tag `vX.Y.Z-testing.N` and publish a **pre-release**. |
| a release | Bump `VERSION` on `main` (via a normal PR). Open `main → release`; it fails if `vX.Y.Z` already exists. Check the DMG from the run, then merge to tag `vX.Y.Z` and publish the **Release**. |
| a hotfix | Branch `hotfix/…` from `release`, PR into `release` (with a `VERSION` bump), then PR the same fix into `main`. |

The `source-guard` check rejects any other PR into `testing` or `release`.

## Branch hygiene

- Merged branches are deleted automatically.
- The weekly **Branch hygiene** workflow deletes branches whose PR was closed without merging more than 14 days ago, and lists branches that never had a PR. Run it manually with *dry-run* to preview.

## Security

Report vulnerabilities privately: see [SECURITY.md](SECURITY.md). Release tags (`v*`) can't be moved or deleted once published.

Changes touching entitlements, IPC routes, storage, networking or signing need a "Security impact" section. `scripts/verify-app.sh` fails the build on any entitlement outside the allowlist, `cs.*` relaxations, stray rpaths, ATS weakening, unstripped symbols or embedded secrets. See [README → Security](README.md#security).

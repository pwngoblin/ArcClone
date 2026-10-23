# Project Development Rules & Guidelines

## Tech Stack & Architecture
- **Language**: Pure native Swift (latest version).
- **UI Framework**: SwiftUI (avoid UIKit/AppKit wrappers unless interacting directly with low-level macOS windowing/WKWebView IPC bridges).
- **Architecture**: Modular layout (`core/`, `injections/`, `agent-bridge/`, `ui/`).
- **Native Standards**: Prioritize native macOS APIs, performance, and memory safety. No cross-platform web wrappers (like Electron).

## Git & GitHub Automation Workflow
When given any task, feature implementation, or bug fix, you MUST follow this git discipline automatically:

1. **Branching**:
   - Always check current branch status (`git status`).
   - If on `main` or `master`, automatically create and switch to a descriptive feature/fix branch (e.g., `feature/svelte-ui`, `fix/wkwebview-ipc`) before writing code.
2. **Commits & Pushing**:
   - Write clean, atomic commits with conventional commit messages (e.g., `feat(core): implement WKScriptMessageHandler bridge`).
   - Push the branch to origin immediately with upstream tracking (`git push -u origin <branch-name>`).
3. **Pull Requests**:
   - Once a feature or fix is complete and pushed, automatically create a Pull Request back to `main` using the GitHub CLI (`gh pr create --title "..." --body "..."`).
4. **Releases**:
   - When explicitly instructed to "create a release", tag the current commit following Semantic Versioning (e.g., `git tag -a v1.0.0 -m "Release v1.0.0"`), push the tag (`git push origin --tags`), and generate a GitHub release using `gh release create v1.0.0 --generate-notes`.

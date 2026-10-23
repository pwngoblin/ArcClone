# Project Development Rules & Guidelines

## Tech Stack & Architecture
- **Language**: Pure native Swift (latest version).
- **UI Framework**: SwiftUI (avoid UIKit/AppKit wrappers unless interacting directly with low-level macOS windowing/WKWebView IPC bridges).
- **Architecture**: Modular layout (`core/`, `injections/`, `agent-bridge/`, `ui/`).
- **Native Standards**: Prioritize native macOS APIs, high performance, and strict memory safety. No cross-platform web wrappers (like Electron).

## macOS & Apple Secure Application Development Standards
All code written for this project must strictly comply with Apple’s platform security guidelines, macOS hardening requirements, OWASP defensive patterns, and threat-mitigation frameworks:

1. **App Sandbox & File-System Scoping (`entitlements.plist`)**:
   - Explicitly configure a strict `entitlements.plist` enabling `com.apple.security.app-sandbox`.
   - Restrict file access to container defaults or explicitly required scopes (e.g., user-selected files via open/save panels using **Security-Scoped Bookmarks** rather than blanket disk permissions).
   - Limit network entitlements strictly to what is necessary (`com.apple.security.network.client` for outbound LLM and web traffic; avoid incoming listener rules unless explicitly architected).

2. **Hardened Runtime & Notarization Readiness**:
   - Ensure code is fully compatible with macOS **Hardened Runtime** protections (disabling arbitrary writable/executable memory `MAP_JIT` unless required, and enforcing library validation to block untrusted dynamic library injection).
   - Avoid runtime execution exceptions unless fundamentally required by low-level browser engine constraints.

3. **Secure Credential & Local State Storage**:
   - **Never** store sensitive data, API tokens, auth credentials, or session cookies in plain text files or standard `UserDefaults`.
   - Always leverage the **macOS Keychain Services API** (Security framework) wrapped securely in modern Swift for any sensitive persistence.

4. **Advanced WebKit & IPC Security (`WKWebView`)**:
   - Enforce strict separation of privileges between the app container and the `WKWebView` process, mitigating injection vectors and cross-site scripting risks.
   - Restrict script injections (`WKUserScript`) and channel custom message handlers (`WKScriptMessageHandler`) behind rigidly typed, schema-validated message payloads. Never evaluate raw, untrusted JavaScript strings containing interpolated user inputs.
   - Implement strict Content Security Policies (CSP) within loaded web content contexts.

5. **Memory Safety & Modern Swift Concurrency**:
   - Use Swift concurrency primitives (`async/await`, `actor`, `@MainActor`) exclusively to eliminate data races and thread-safety violations at compile time.
   - Avoid unsafe pointers (`UnsafeMutablePointer`, etc.) unless interacting directly with core AppKit/WebKit graphics or system buffers under strict isolation.

## Git & GitHub Automation Workflow
When given any task, feature implementation, or bug fix, you MUST follow this git discipline automatically:

1. **Branching**:
   - Always check current branch status (`git status`).
   - If on `main` or `master`, automatically create and switch to a descriptive feature/fix branch (e.g., `feature/secure-ipc`, `fix/keychain-token-storage`) before writing code.
2. **Commits & Pushing**:
   - Write clean, atomic commits with conventional commit messages (e.g., `feat(core): implement secure WKScriptMessageHandler bridge`).
   - Push the branch to origin immediately with upstream tracking (`git push -u origin <branch-name>`).
3. **Pull Requests**:
   - Once a feature or fix is complete and pushed, automatically create a Pull Request back to `main` using the GitHub CLI (`gh pr create --title "..." --body "..."`).
4. **Releases**:
   - When explicitly instructed to "create a release", tag the current commit following Semantic Versioning (e.g., `git tag -a v1.0.0 -m "Release v1.0.0"`), push the tag (`git push origin --tags`), and generate a GitHub release using `gh release create v1.0.0 --generate-notes`.
# Project Development Rules & Guidelines

## Tech Stack & Architecture
- **Language**: Pure native Swift (latest version).
- **UI Framework**: SwiftUI (avoid UIKit/AppKit wrappers unless interacting directly with low-level macOS windowing/WKWebView IPC bridges).
- **Architecture**: Modular layout (`core/`, `injections/`, `agent-bridge/`, `ui/`).
- **Native Standards**: Prioritize native macOS APIs, high performance, strict memory safety, and optimized binary/app bundle sizing. No cross-platform web wrappers (like Electron).

---

## Product Vision, UX, & Engineering Philosophy
- **Product Manager Mindset**: Act as both an elite systems engineer and a visionary product manager. Evaluate every feature through the lens of user delight, workflow friction reduction, architectural elegance, and distinct competitive value on macOS.
- **Extreme Resource Efficiency (Green/Lean Computing)**: Ruthlessly minimize CPU cycles, RAM footprint, disk I/O, and battery/energy impact. Every module must target zero background wake-ups, aggressive memory recycling, and maximum performance on Apple Silicon (M-series unified memory optimization).

---

## Cross-Browser Migration Engine (`core/migration/`)
- Provide a robust, frictionless native migration module to import bookmarks, browsing history, and open tabs from major macOS browsers (**Google Chrome, Apple Safari, Zen, Arc, Dia**).
- Use `NSOpenPanel` with **Security-Scoped Bookmarks** to acquire explicit user permissions safely outside the sandbox.
- Parse SQLite databases (`SQLITE_OPEN_READONLY`) and property lists asynchronously inside dedicated `actor` boundaries (`MigrationActor`) with zero main-thread blocking.
- Implement automated deduplication and normalization of URLs/timestamps to unify profiles cleanly.

---

## Tab Virtualization, Hibernation, & High-Scale Performance (`core/tabs/`)
- **Metadata-First Architecture**: Support 5,000+ tabs effortlessly by storing background tabs purely as lightweight value types (`struct TabItem`), keeping active `WKWebView` instances strictly limited to the visible viewport pool.
- **Automatic Hibernation**: Unload `WKWebView` instances for background tabs idle for over 30 minutes, freeing memory while preserving state metadata.
- **UI Virtualization**: Utilize SwiftUI lazy containers (`LazyVGrid`) for tab sidebars and exposés to maintain a rock-solid 60/120Hz frame rate under massive loads.

---

## macOS & Apple Secure Application Development Standards
All code written for this project must strictly comply with Apple’s platform security guidelines, macOS hardening requirements, OWASP defensive patterns, and threat-mitigation frameworks (zero trust, zero leakage, and absolute attack surface minimization):

1. **App Sandbox & File-System Scoping (`entitlements.plist`)**:
   - Explicitly configure a strict `entitlements.plist` enabling `com.apple.security.app-sandbox`.
   - Restrict file access to container defaults or explicitly required scopes (e.g., user-selected files via open/save panels using **Security-Scoped Bookmarks** rather than blanket disk permissions).
   - Limit network entitlements strictly to what is necessary (`com.apple.security.network.client` for outbound traffic; avoid incoming listener rules unless explicitly architected).
   - Disable dangerous capabilities such as unsigned executable memory (`com.apple.security.cs.allow-unsigned-executable-memory`) and restrict debugging/dynamic library injection (`--options restrict`).

2. **Hardened Runtime, Compiler Settings & Notarization Readiness**:
   - Ensure code is fully compatible with macOS **Hardened Runtime** protections (`--options runtime`).
   - Enforce strict library validation by default to block untrusted dynamic library injection (`DYLD_INSERT_LIBRARIES` hooks, Frida, or debugging attachments).
   - Require `SWIFT_STRICT_CONCURRENCY = complete` in build settings to catch data races during compilation.
   - Configure compiler optimization settings (`SWIFT_OPTIMIZATION_LEVEL = -O` for release builds, dead-code stripping enabled, and link-time optimization/LTO active) to maximize runtime CPU/memory performance and minimize final binary size.

3. **Secure Credential, State, & IPC Storage**:
   - **Never** store sensitive data, API tokens, auth credentials, or session cookies in plain text files or standard `UserDefaults`.
   - Always leverage the **macOS Keychain Services API** (Security framework) wrapped securely in modern Swift, utilizing explicit attributes (e.g., `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and secure Access Control Lists (ACLs).
   - Eliminate all uses of vulnerable shell-execution wrappers (`system`, insecure `Process`/`NSTask` launching via shell). When spawning helper processes in Swift, invoke binaries directly with absolute paths, passing arguments strictly as an array (`arguments: [String]`) rather than a concatenated command string to completely nullify argument injection and privilege escalation.

4. **XPC Services & Helper Boundary Hardening (LPE Prevention)**:
   - When communicating across processes using `NSXPCConnection` or helper tools, validate the client process identity (`SecCodeValidateForProcess`) using Apple Code Signing requirements before processing any request.
   - Design XPC interfaces to follow the Principle of Least Privilege: expose minimal, non-privileged primitives rather than high-level execution endpoints.

5. **Advanced WebKit, JavaScript, & Bridge Security (`WKWebView` / JavaScriptCore)**:
   - Enforce strict separation of privileges between the app container and the `WKWebView` process, mitigating injection vectors and cross-site scripting risks.
   - Restrict script injections (`WKUserScript`) and channel custom message handlers (`WKScriptMessageHandler`) behind rigidly typed, schema-validated JSON message payloads. 
   - **Never** evaluate raw, untrusted JavaScript strings containing interpolated user inputs, and ban the use of `eval()`, `setTimeout(string)`, or `innerHTML` assignments that evaluate dynamic input.
   - Enforce strict Content Security Policies (CSP) within loaded web content contexts, disallowing inline scripts (`unsafe-inline`) and restricting script loads strictly to trusted self-hosted origins. Ensure universal file access is disabled (`allowFileAccessFromFileURLs = false`).

6. **Structured Logging & Data Privacy Enforcement**:
   - Standard `print()`, `NSLog()`, or custom unredacted loggers are **strictly forbidden**.
   - Use Apple's `os.Logger` framework exclusively. Explicitly mark dynamic values, tokens, paths, and user payloads with privacy qualifiers (e.g., `logger.debug("Token: \(token, privacy: .sensitive)")`) to prevent accidental sensitive leakage into system crash logs or Console.app.

7. **Shell Script Security & Automation Guardrails**:
   - Every auxiliary or helper shell script must begin with `set -euo pipefail` to ensure scripts fail instantly on unbound variables, pipeline errors, or unexpected command exits.
   - Explicitly override and lock down the `PATH` variable at the top of scripts (e.g., `export PATH="/usr/bin:/bin:/usr/sbin:/sbin"`). Never rely on an inherited, user-controlled `PATH`.
   - Double-quote every single variable expansion (e.g., `"$VAR"`) to prevent word splitting and globbing injection attacks.
   - When creating temporary files or directories, use `mktemp -d` with strict file permissions (`umask 077`) to prevent race conditions (TOCTOU) and local information disclosure.

8. **Memory Safety, Performance Profiling & App Size Optimization**:
   - Use Swift concurrency primitives (`async/await`, `actor`, `@MainActor`) exclusively to eliminate data races and thread-safety violations at compile time.
   - Avoid unsafe pointers (`UnsafeMutablePointer`, etc.) unless interacting directly with core AppKit/WebKit graphics or system buffers under strict bounds-checked isolation. Ensure sensitive memory buffers are zeroed out upon deallocation.
   - Sanitize all system error messages thrown or exposed to the UI layer to prevent stack trace disclosures, internal directory path exposures, or detailed system state leaks.
   - Regularly profile code using Xcode Instruments (Leaks, Allocations, and Time Profiler) to ensure zero memory growth, zero leaks, and efficient CPU usage on Apple Silicon.
   - Enforce binary size hygiene by stripping local symbol tables (`strip -x` on release binaries), removing unused assets, and leveraging dead-code stripping (`DEAD_CODE_STRIPPING = YES`).

9. **Supply Chain & Dependency Integrity (SPM)**:
   - All third-party dependencies imported via Swift Package Manager (SPM) must be pinned to exact semantic versions or specific cryptographic commit hashes (`exactVersion` or `revision`) to eliminate supply chain tampering risks.

---

## WebExtension & Native Messaging Architecture (`core/`, `injections/`, `agent-bridge/`)
To enable official WebExtensions (such as 1Password, Bitwarden, or standard Manifest V3 extensions) directly within the native Swift/WebKit architecture, the codebase must conform to the following module contracts:

1. **Manifest V3 Specification & Metadata Parsing (`core/ExtensionManifest.swift` & `core/ExtensionManager.swift`)**:
   - `ExtensionManifest` must be fully `Codable` and `Sendable`, supporting `manifest_version`, background scripts/service workers, permissions, and content script matchers.
   - `ExtensionManager` must operate inside an `@globalActor` or isolated `actor` context (`ExtensionActor`), loading extensions asynchronously from local directory URLs inside sandboxed paths without blocking the UI thread.

2. **WebKit Script Injections & Schema-Validated Bridge (`injections/ExtensionScriptInjector.swift` & `injections/ExtensionMessageBridge.swift`)**:
   - Inject extension content scripts into `WKWebView` instances via `WKUserScript` bound to `WKUserContentController`.
   - Implement `ExtensionMessageBridge` as a `WKScriptMessageHandler` that accepts schema-validated JSON payloads (`action`, `payload`).
   - Block dynamic string evaluation (`eval`, string-based `setTimeout`) and enforce `os.Logger` for event tracing.

3. **Secure Native Messaging IPC Host (`agent-bridge/NativeMessagingHostManager.swift`)**:
   - 1Password integration requires IPC communication with the 1Password desktop companion via `chrome.runtime.connectNative()`.
   - `NativeMessagingHostManager` must be an `actor` that locates native messaging host JSON manifests in standard system locations (`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`).
   - Spawn host binaries via `Process()` directly using absolute paths and strict array arguments (`arguments: [String]`). **Never** route through `/bin/sh` or system shells. Connect standard input and output pipes (`stdin`/`stdout`) for length-prefixed JSON IPC messaging.

4. **UI Action Integration (`ui/ExtensionToolbarView.swift`)**:
   - Provide clean SwiftUI controls for extension toolbar buttons, popup anchors, and badges using SF Symbols and native macOS layout paradigms.

---

---

## WebKit Extension Runtime: Hard-Won Rules (macOS 15.4+, `WKWebExtensionController`)
Read `docs/EXTENSIONS.md` → *Debugging an extension* before touching extensions. Each rule below cost a debugging session:
- **Popups**: present `WKWebExtension.Action.popupPopover` (not a hand-made popover around `popupWebView`). An extension that calls `action.setPopup("")` (1Password without an account) opens a tab on click by design.
- **Extension pages in tabs** (`webkit-extension://`) must load in a web view made from `context.webViewConfiguration`; a normal tab web view renders them blank. WebKit silently drops main-frame navigations from an extension web view to http(s), so `Tab` cancels them and reloads in a regular web view (`Tab.swift` decidePolicy, `WebViewFactory.extensionConfiguration(for:)`).
- **Never let WebKit suspend extension processes**: the controller's web view configuration uses `inactiveSchedulingPolicy = .none` (`ExtensionManager.configuration()`). With the default `.suspend`, the hidden background was suspended mid-task right after each message. WebKit still unloads an idle MV3 background after ~30 s; messages wake it.
- **WebSocket in a service worker deadlocks WebKit** (worker runs on the web process main thread; `wss://` constructor waits on itself). The worker shim replaces `WebSocket` with one bridged through Lily (`dev.lily.websocket`, `ExtensionWebSockets.swift`). This was the 1Password "sign-in spins forever" bug. Suspect similar sync-bridge APIs if a background goes silent.
- **Native-messaging ports**: a port carries messages only after the `connectUsing` delegate call returns. Lily sends `{type: "ready"}` first; the shim waits for it.
- **Lily's reserved native-messaging names**, answered in-process (everything else is refused): `dev.lily.notifications`, `dev.lily.websocket`, `dev.lily.console`. Every extension with a background is granted `nativeMessaging` so the shim can reach them.
- **The worker shim** (`injections/extension-worker-compat.js`) is applied before the audit and pinned with the extension. After changing it, the extension must be **removed and re-added** to pick it up.
- **Shadowing WebKit's `chrome.runtime` members doesn't work**; wrapping event methods (`onMessage.addListener`) does.
- `context.errors` keeps only ~25 entries; don't use it to count things in tests. Measure via observable state (badge text, action title).
- Tests: never fixed sleeps for async WebKit work; `await context.loadBackgroundContent()` and poll for a handshake/state (CI is slow and flaky otherwise).

## Local Builds, Signing & Testing With the User
- Build app for the user with `CODESIGN_IDENTITY="<Apple Development identity, see security find-identity -v -p codesigning>" make app` (free Apple Development cert, team V56242Q2KF) → `build/Lily.app`; the user copies it to /Applications. Ad-hoc builds lose Keychain-sealed data (extensions, history, session) on every rebuild.
- **Never run the signed app or its `--self-test` while the user is testing**: it shares the user's sandbox container and causes freezes. `make selftest` (unbundled debug binary) is fine.
- The signed app's container is not readable from the terminal ("Operation not permitted"); rely on logs.
- No paid Apple Developer account yet: 1Password desktop-app unlock / real native-messaging hosts are parked until Developer ID signing exists.
- Before a PR: `make lint`, `cd core && swift test`, `make selftest`, `make perf`.

---

## Git & GitHub Automation Workflow
When given any task, feature implementation, or bug fix, you MUST follow this git discipline automatically:

1. **Branching**:
   - Always check current branch status (`git status`).
   - If on `main` or `master`, automatically create and switch to a descriptive feature/fix branch (e.g., `feature/secure-ipc`, `fix/keychain-token-storage`) before writing code.
2. **Pre-Commit Static Analysis**:
   - Run SwiftLint / SwiftFormat or built-in security linters prior to committing to ensure no hardcoded secrets, unsafe pointers, or banned logging calls exist.
3. **Commits & Pushing**:
   - Write clean, atomic commits with conventional commit messages (e.g., `feat(core): implement secure WKScriptMessageHandler bridge`).
   - Push the branch to origin immediately with upstream tracking (`git push -u origin <branch-name>`).
4. **Pull Requests**:
   - Once a feature or fix is complete and pushed, automatically create a Pull Request back to `main` using the GitHub CLI (`gh pr create --title "..." --body "..."`).
5. **Releases**:
   - When explicitly instructed to "create a release", tag the current commit following Semantic Versioning (e.g., `git tag -a v1.0.0 -m "Release v1.0.0"`), push the tag (`git push origin --tags`), and generate a GitHub release using `gh release create v1.0.0 --generate-notes`.

---

### PR & Performance Gate Rule
- Before finalizing a feature or running `gh pr create` for any code changes touching `core/tabs/`, memory, or UI virtualization:
- Automatically check if the tab virtualization or memory constraints could be impacted.
- Prompt to run (or verify) the `TabManagerPerformanceTests` suite to ensure 5,000+ tab memory overhead and search speed meet performance targets before the PR is created.
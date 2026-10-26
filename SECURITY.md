# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately through GitHub:
**[Security → Report a vulnerability](https://github.com/pwngoblin/Lily/security/advisories/new)**.

Include what you found, how to reproduce it (a minimal page, extension or steps), the Lily version
(About Lily, or the DMG name) and your macOS version. Lily is maintained by one person, so replies are
best effort; you'll get an acknowledgement, and a credit in the advisory if you want one.

## Supported versions

Only the latest release and `main` get security fixes.

## Scope

In scope, Lily's own code and configuration, for example:
- the page ↔ native bridge (`IPC/`, `injections/`): reaching it from a website or an extension, schema or origin-check bypasses
- web extension install, audit, pinning and isolation; the `dev.lily.*` native-messaging names
- data at rest (sealed files, Keychain keys), private windows leaking data, sandbox entitlements
- the build and release pipeline (`scripts/`, `.github/`)

Out of scope: bugs in WebKit or macOS itself (report them to [Apple](https://security.apple.com)),
third-party extensions' own behavior, and attacks that need an already-compromised Mac or user account.
How Lily is hardened: [README → Security](README.md#security) and [docs/EXTENSIONS.md](docs/EXTENSIONS.md).

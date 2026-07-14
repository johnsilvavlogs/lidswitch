# Security Policy

LidSwitch is a small local macOS utility that changes power-management settings
through a privileged helper. Please report security issues privately before
opening a public issue.

## Supported Versions

Until the first public release exists, only the current `main` branch is
supported.

## Reporting A Vulnerability

Use GitHub's private vulnerability reporting if it is enabled for this
repository. If it is not available, open a minimal GitHub issue that does not
include exploit details or sensitive local information, and ask for a private
contact path.

Useful reports include:

- affected macOS version and Mac model
- LidSwitch version or commit
- whether the app was installed from a DMG or built locally
- exact helper/install/restore behavior observed
- steps to reproduce, with secrets and personal paths redacted

## Scope

In scope:

- raw-XPC request and reply identity, strict message schemas, replay resistance,
  connection lifetime, and session ownership
- same-UID local substitution or confused-deputy attacks that could cross into
  the privileged helper
- privileged filesystem ownership, mode, link, path-swap, publication,
  recovery, and durability races
- lease expiry, app/helper death, disconnect, restore, and no-rearm behavior
- helper install, restore, or uninstall behavior
- LaunchDaemon plist generation
- power-setting restore safety
- local preference-file handling
- DMG packaging or install instructions that could mislead users

## Manual ad-hoc trust boundary

The manual release channel pins exact code identity and artifact bytes, but it
does not establish publisher identity. A byte-for-byte copy has the same code
identity and is intentionally indistinguishable at that boundary. Modified or
re-signed code must be rejected; provenance and notarization require a future
Developer ID release with separate end-to-end evidence.

User-owned diagnostic or migration files are not privileged authority. A
same-UID process may be able to alter those files; the root helper must rely on
its authenticated connection and root-owned state instead of promoting user
state into authorization.

Out of scope:

- social engineering against recipients
- issues that require modifying the user's local checkout before building
- reports based only on the app being unsigned or not notarized, which is
  intentionally disclosed for this small manual release

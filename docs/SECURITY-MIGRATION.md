# Authenticated helper channel migration

## Shipping boundary

In version 0.2.11, version 0.2.9's file lease is not a privileged authorization mechanism. The production helper entry point accepts work only through the `com.johnsilva.lidswitch.helper.control` raw libxpc Mach service. The legacy activation-lease file can remain as inert diagnostic evidence during migration, but the LaunchDaemon has no `WatchPaths` entry and neither the helper nor its listener reads the file.

The C bridge calls `SecCodeCreateWithXPCMessage` on each received request object before reading any request key. It checks strict code validity, the enrolled effective UID, identifier, and exact CDHash. The app applies the same message-derived check to the helper's received reply before reading reply fields. A rejected identity is never passed to Swift. The allowlisted protocol is version 2 and has a fixed primitive schema whose logical maximum is less than 1024 bytes.

## Manual/ad-hoc trust truth

The manual profile pins the exact administrator-enrolled app and helper code content. This prevents a different same-UID program, a same-identifier/different-CDHash build, and a swapped helper source from acquiring authority. It does **not** establish publisher identity: a byte-for-byte copy of the enrolled app remains the same code and can authenticate. That exact-copy residual is explicit and must not be described as Developer ID assurance.

The stronger profile requires an Apple-anchored Developer ID signature, the enrolled Team ID and identifiers, strict validity, and exact CDHashes. Distribution still requires external Developer ID credentials, hardened-runtime signing, notarization, stapling, and Gatekeeper verification. There is no automatic fallback from this profile to manual/ad-hoc.

## Install and rotation

Before the administrator prompt the app reads the bundled helper once through an `O_NOFOLLOW` descriptor, bounds it to 16 MiB, verifies regular-file/single-link/stable inode and size, writes one frozen private stage, and derives SHA-256 and strict code identity from that frozen copy. The current running app identity is frozen at the same point. The privileged transaction copies the frozen source once into a root-only stage outside the authority-state directory and never reopens the user source. It then revalidates type, link count, size, SHA-256, strict signature, identifier, and CDHash. A mutable `.administrator-<uuid>` stage inside the authority-state directory is an unsafe inventory and blocks both pristine bootstrap and migration; it is never ignored as operational noise.

The helper, enrollment policy, and version are committed as one `Current` directory. The LaunchDaemon plist is committed only after safe-idle bootout and rollback. A failed bootstrap restores `Previous`; there is never a file-lease fallback channel. Updates intentionally rotate both exact pins under a fresh administrator-approved safe-idle transaction.

Administrator work uses the same closed, process-group-contained `osascript`
runner as every other bounded subprocess. The root wrapper publishes a
transaction-matched, root-owned `0644` receipt before bootout. A verified helper
one-shot produces the canonical terminal payload; the wrapper publishes it only
after install rotation/bootstrap, restore restart, or uninstall removal is
complete. The app accepts only the exact schema, UUID, operation, terminal
state, session, and bounded reason. Timeout plus an absent, malformed, or still
running receipt is completion-indeterminate—it is never reported as
cancellation. Reconciliation is finite, so neither the UI nor a root child can
create an unbounded polling wait.

Install, uninstall, and explicit restore share one descriptor-held
`lockf` transaction lock under `/private/var/run`. A competing app instance
is classified as not started (using an exact receipt when the existing product
root is valid) and performs no launchd, recovery, power, or installation
mutation. The lock is released by descriptor lifetime, so a
crash cannot leave a stale ownership token that a later transaction guesses
away.

## Runtime authority

Only one authenticated connection owns one session. `begin` is the only first-activation operation. `renew`, `end`, and `snapshot` must match both connection and UUID; `restore` is restricted to the owning connection while active. The helper chooses the 30-second monotonic expiry. Unknown keys, wrong types or version, malformed UUIDs, stale renewals, second connections, and protocol failures fail closed.

Before listening after a restart, the helper permits only a bounded same-boot reconnect candidate whose private applied authority, live process tuple, original monotonic lease deadline, power state, proof, and both ledgers still agree. Any mismatch restores and durably terminalizes the UUID; restart never creates a new lease or extends the old one. Connection invalidation, expiry, confirmed AC loss, drift, or protocol failure also restores and terminalizes. Battery is immediate. A single unknown power observation does not renew; two consecutive observations terminate. A one-time SleepDisabled-only recovery requires a durable reservation before reapply, and the reservation makes a crash/restart non-resumable.

The helper's explicit provision one-shot creates or verifies only the fixed
root-state lock. The administrator must then prove both legacy and current
launchd writers are stopped before the recovery one-shot may inventory history,
create or migrate ledgers, publish proof, or touch native power. Daemon startup
without that proof is observation-only. The administrator wrapper never parses
or edits applied state, power baselines, ledgers, proof, or status. The recovery
one-shot returns typed pristine idle, migrated idle, terminal idle, durable
recovery-required, or internal failure (`0`, `0`, `0`, `75`, or `78`). Migrated
idle is canonical `session=none`; a synthetic UUID and a pristine label are
both forbidden when any recognized history exists.

Shipped v0.1 state may contain strict root-owned helper/status/install history
and `original-ac-sleep` or `original-battery-sleep` without any applied-state
session UUID. Recovery accepts only regular, single-link, stable exact-EOF
timer bytes at modes `0600`, `0640`, or `0644`, owned by root with wheel/admin
historical group compatibility, and canonical integers `0...1440`. It migrates
those bytes to private `0600` evidence and publishes a private crash journal
before the first setter. A valid idle status must be `inactive/session=none`; a
terminal status must match the newest terminal ledger UUID. Unknown leaves,
mutable administrator stages, symlinks, hardlinks, writable entries, malformed
status/version bytes, one-sided unmarked ledgers, unsafe ancestors, oversize or
changing files, and invalid proof are preserved and fail closed.

The production root capability accepts exactly
`/Library/Application Support/LidSwitch`: `/` and `/Library` are root:wheel
`0755`, the canonical `Application Support` ancestor is root:admin `0755`, and
the final LidSwitch directory is root:wheel `0755`. The admin-group exception
does not apply to an arbitrary ancestor or final directory. Every component is
opened with `O_NOFOLLOW`, and mode equality includes all `07777` permission and
special bits, so a symlink, setuid/setgid/sticky bit, or ownership/mode
deviation is rejected.

Timer restoration is conditional and non-destructive. Equal current/target
values require no setter; current `0` plus a positive target restores and
rereads; any different positive current value is retained as superseding
evidence; target/current `0` is already satisfied; target `0` never causes a
setter. `superseded-N` permits only canonical `N` in `1...1440`, different from
the target; zero is never superseding evidence. A second read at the mutation
boundary prevents overwriting a value installed after planning. A nil required
native field performs no setter and
retains the journal and original evidence. Only timer evidence owns a legacy
`SleepDisabled` clear; helper/plist presence alone never does. Once the journal
is native-safe or proof-published, re-entry is observation-only and can never
rearm. Original timers and journal quarantines are removed or resumed only
after a durable migrated proof and verified native safe idle.

Journal parsing enforces the full phase matrix: present targets are exactly
`pending` while prepared; absent targets are exactly `not-required`; and safe
phases contain only internally possible satisfied, restored, or canonical
superseded conclusions. A migrated proof is immutable. Crash replay requires
its sessionless reason and every journal disposition to match the journal and
fresh native values exactly; mismatch preserves proof, journal, and evidence
and returns recovery-required without a setter or proof rewrite.

Historical four/six-key applied state and every schema-2 applied record are
descriptor-validated restore-only evidence, regardless of root:wheel ownership,
`0600`/`0640`/`0644` mode, a live owner tuple, future lease, proof, or journal.
Schema 3 is the sole current authority schema and is emitted only by the current
helper; mode is metadata and cannot promote schema 2. Before a proof, ledger,
setter, cleanup, status rewrite, or evidence removal, incompatible completed
proof plus schema-2 evidence returns recovery-required unchanged. Where an
operator-authorized proof-absent/recovery-required retry may restore legacy
evidence, recovery first publishes an owner/lease-free projection; a crash can
therefore never leave process-bound schema-2 bytes that restart may adopt.
Every `04600`/`02600`/`01600` authority leaf and special-bit authority directory
is rejected. Missing or unsafe ledgers deny new sessions, except that an exact legacy
applied record, a legacy crash journal, or a verified pristine proof with no
applied evidence may resume only its own partial publication under those proof
rules.
All four/six/12/14-key applied records require exact canonical bytes: fixed
field order, lowercase UUIDs, canonical integers and floating-point text, one
final newline, and no extra or interior blank lines. Both documented legacy
four- and six-key shapes remain accepted, including a canonical six-key no-op.
Pristine or terminal idle is accepted only when a fresh native power snapshot
also proves `SleepDisabled=false`. This is unconditional even for no-op and
AC-only legacy evidence: without recorded ownership, the helper never clears an
observed global override, publishes terminal proof, removes evidence, or exits
successfully merely to make an idle proof pass.
Ledger publication is bounded to 64 UUIDs and requires temp-file full sync,
atomic rename, parent-directory sync, final-inode sync, and final
parse/equality verification before ownership can be cleared or success
returned.

Wall time is informational. Helper authority and expiry use monotonic time. Status records carry boot ID and monotonic update time so clock changes do not terminate a valid session.

## Required release proof

This source cutover is not accepted until a clean macOS 14+ environment completes:

- Swift/C compilation and XCTest, including the raw-XPC security fixture suite.
- Positive exact app/helper peers and negative UID, CDHash, identifier, schema, type, key, size, UUID, session, second-connection, stale-renewal, invalidation, restart, and exact-copy controls.
- Installer source-swap, symlink, FIFO, device, socket, hardlink, extra-path, oversize, timeout/descendant, rollback, and update-rotation controls.
- Non-power state-machine integration using fixture power only, then a separately authorized safe live canary proving begin/renew/end, disconnect, app death, helper death, restart-first restore, and no automatic resume.
- Per-message identity benchmark on supported hardware.
- Developer ID signing/notarization/Gatekeeper proof before claiming publisher identity.

Until those gates pass, the migration implementation and fixtures are
**source-only / runtime-verification-blocked**, not production-certified.

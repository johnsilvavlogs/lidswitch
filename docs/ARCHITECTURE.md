# Architecture

LidSwitch `0.2.12` is a SwiftPM menu bar app with four targets:

- `LidSwitch`: UI, inspection, authenticated raw-XPC client, installation, and recovery controls.
- `LidSwitchCore`: shared wire schemas, release identity, bounded file primitives, monotonic clock, boot identity, and compatibility policy.
- `LidSwitchXPCBridge`: the strict C/libxpc request and peer-identity boundary.
- `LidSwitchHelper`: compiled root helper using IOKit power notifications and bounded timers.

## Session flow

1. The user prepares helper version `5` in the root-owned `Current` directory; legacy login and shell-helper artifacts are removed while protection remains off.
2. The user confirms **Start Plugged-In Session** on AC power.
3. The app begins an authenticated raw-XPC session. The legacy user-owned activation lease is inert diagnostic/migration state only; it cannot authorize the helper.
4. launchd exposes one authenticated Mach service. It has no `WatchPaths` or `StartInterval` trigger.
5. The helper verifies the enrolled caller identity, session UUID, current AC power, and settings before changing anything.
6. Before changing anything, the helper writes a root-owned applied-state record. It then applies AC sleep `0` when needed and `SleepDisabled=1`, verifying both.
7. A serial `DispatchSourceTimer` coordinator accepts **active** only when the lease, fresh helper acknowledgement, session UUID, and direct AC source agree. It never depends on the main run loop or a full `PowerInspector.snapshot`, and it is the sole termination authority for an owned active generation.
8. The coordinator renews every 8 seconds using monotonic deadlines. Immediately before atomic lease publication, it rechecks the prior expiry and fresh matching helper/AC state.
9. The root-owned private `0600` `terminal-generations` ledger is the authoritative tombstone, bounded to the newest 64 session UUIDs; helper status remains the public acknowledgement surface. Replaying a fresh lease with a tombstoned UUID cannot reactivate the helper.
10. Install, Restore, Quit fallback, and Remove use one staged verified helper:
    provision the fixed root lock, run one typed recovery intent, require exact
    safe-idle proof, and only then publish or remove generations. The
    administrator shell owns staging/launchd/receipt mechanics only; its mutable
    candidate stage is outside the authority-state directory, and it has no
    power or recovery-state parser.

Helper preparation first provisions or verifies only the fixed lock. After the
administrator proves old writers stopped, native recovery descriptor-migrates
private root-owned `0600` ledgers and recovery proof. It never replaces
malformed or ambiguous history with an empty ledger. The ordinary-user app
treats those files as opaque and consumes the public bounded helper-status
projection plus native power state for readiness.

The legacy no-session migration is a separate state machine. A held
root-directory capability and the same fixed `RootStateLock` first classify a
bounded, stable inventory. Recognized v0.1 history produces a private
`legacy-recovery-journal`, never pristine proof or a guessed UUID. Journal
phases are `prepared`, `native-safe`, and `proof-published`; each transition is
full-synced, atomically published, directory-synced, reopened, parsed, and
identity-verified. Re-entry derives the next action from the journal plus fresh
native reads. Setter-throw-after-mutation, proof publication, quarantine rename,
and final cleanup are therefore idempotent and never reapply `0` or rearm an
override.
The journal parser rejects impossible phase/disposition cross-products. Once a
sessionless migrated proof exists, its bytes are immutable; replay accepts only
an exact native-safe/proof-published journal reason and exact fresh native
values, then advances only the journal/cleanup boundary.
Applied authority has an explicit provenance boundary: only canonical private
schema-3 state can be current process-bound authority. Schema 2 and historical
four/six-key state are restore-only at every mode and ownership combination;
chmod cannot promote them. Quiesced recovery rejects incompatible completed
proof before any authority mutation, and authorized legacy recovery strips
owner and lease fields before publication. Terminal safe-idle proof, cleanup,
and successful recovery additionally require a fresh global
`SleepDisabled=false`, including no-op or AC-only records.

## End and recovery

Unplug, quit, reboot, app death, lease expiry, invalid input, lost acknowledgement, signal, or setting drift ends the session. One exception is a single owned `SleepDisabled=0` loss while AC, the matching current lease, applied-state, helper session, and nonterminal generation all still agree: the connected `HelperControlService` tick routes that exact observation into the one-time repair path, records a root-owned bounded `recovery_budget=reserved` marker before mutation and `spent` after success, then reapplies `SleepDisabled=1` to the same UUID. The marker survives helper restart; a restart while reserved fails closed, while a restart with spent budget retains the spent state. App and helper inspections use IOKit plus `CFPreferences` reads of `com.apple.PowerManagement`; failed synchronization or unreadable helper values are indeterminate and fail closed. Only privileged mutations use bounded `pmset` commands. The release helper does not inherit the retired runtime's 100/300 ms tolerance loop: direct unreadable values trigger no setter action and leave durable authority for explicit recovery. A second owned loss in that generation, explicit AC-sleep drift, terminal markers, or a failed reapply also terminalizes and restores. Restoration:

- clears `SleepDisabled` only when LidSwitch recorded ownership;
- restores AC sleep only if the current value still equals LidSwitch's applied `0`;
- never applies a stale saved value of `0`;
- verifies restoration; timer backoff is observation/status-projection only,
  and never retries a power setter;
- retains applied-state and emits `recovery-required` on failure.

launchd uses `KeepAlive.SuccessfulExit=false` with throttling only to recover abnormal helper exits. Clean expiry and clean restoration exit successfully and do not persist.

After the app heartbeat observes a terminal helper state, the menu remains in a bounded restoring state while authoritative observation resolves the terminal predicate. There is no universal 30-second setter-retry window: timer work may observe native/status state and retry a failed status projection only. A typed red rollback-verification alert is shown only if observation still cannot prove `SleepDisabled=0`, no activation lease, and no helper recovery marker. Every later authoritative snapshot (bootstrap, manual refresh, timer, and power-source observer) rechecks that exact predicate; it clears only that typed alert when no newer local session exists, announces the safe-idle transition once, and retains all generic operation errors and unsafe/unknown snapshots. Only an explicit user Restore may initiate another setter attempt.

## Contained command cleanup and status projection

Every bounded `pmset`/`launchctl` command is direct-exec only. Darwin
`posix_spawn` starts the child suspended; the runner obtains a bounded
`kern.procargs2` argv observation, PID birth tuple, PGID/SID, executable path,
and complete argv fingerprint before persisting a root-private
`contained-process-receipt` in the current authority transaction. Only then is
that exact PID resumed. If receipt persistence fails, the still-suspended exact
PID is killed and synchronously reaped before the runner returns. A normal
exact reap removes the same receipt; timeout and I/O paths refresh that receipt
under a bounded total lifetime rather than create a second handoff.

Every receipt member carries its own PID birth tuple, executable path, and
complete argv fingerprint; a descendant is never assigned the leader binding.
A later unrecorded descendant forces an ambiguity fence without signaling it.
Cleanup claims or retries at an expired foreign owner deadline under the root
lock, then performs at most one signal/reap action outside that lock. Before a
signal it rechecks each recorded PID's birth tuple, executable, complete argv
fingerprint, PGID, and SID. Extinction requires repeated identical empty process-group inventory;
early reap, PID reuse, a new member, PGID/SID mismatch, unreadable inventory,
bounded EINTR exhaustion, ECHILD, or an owner deadline retain the receipt/mutation fence and project
typed `containment-extinction-unproven` state. TERM intent/issued and KILL
intent/issued are separately persisted, so restart takeover never rewinds KILL
or emits a second signal. Each owner-bound nonblocking reap observation is
CAS-persisted before `waitpid`; an unproven observation may retry only within
the finite owner lease and bounded attempt count. At either limit the receipt
transitions once to retained `ambiguous`, never removes the receipt, emits no
new signal, and schedules no automatic cleanup. Any ambiguity, including total-lifetime expiry,
persists the terminal `ambiguous` phase; receipt removal follows only a
persisted `extinguished` phase, which itself requires a durable EINTR-safe
parent-reap latch plus stable empty inventory, and exact durable removal.

Public `helper-status` is deliberately not authority. Each authoritative
`HelperControlService`/`RecoveryCoordinator` status change writes a strict root-private
`status-projection-task` in the same root transaction before it is considered
converged. A task contains a token/CAS generation, authority snapshot digest,
session, reason digest, boot identity, immutable public payload times, attempt,
deadline, and next attempt. A single status-only dispatcher hydrates the task
before recovery mutation, coalesces an identical target, gives a changed target
a newer generation, resets monotonic retry timing safely on boot change, and
performs bounded backoff outside root-state transactions and the containment
queue. A separate root-private monotonic generation watermark survives task
removal and restart, so a later authority never reuses an old generation.
Public writes carry the generation/authority and are serialized by a dedicated
descriptor-held projection lock in the verified support directory. The writer
uses bounded no-follow leaf reads, exact owner/GID/type/link/mode/size checks,
descriptor-relative exclusive temps, `fsync`/`F_FULLFSYNC` data barriers,
directory-entry synchronization, exclusive install or verified swap, and final
reopen/byte/identity proof. It never renames over or unlinks an unverified
same-UID leaf, so an older retry cannot overwrite a later authority snapshot.
Unsafe, I/O, indeterminate, stale, and equal-generation-conflict
writer outcomes remain typed dirty-task evidence rather than collapsing to
absence or success. The task clears only after an exact public-file write, directory
durability, and reopen proof; retry exhaustion stays as explicit durable work
with no reschedule. The dispatcher owns no setter, lease, authority/session
creation, XPC, or timer work. A failed or ambiguous projection stays dirty and
never causes a power mutation or an authority retry.
The projection lock and its one fixed `helper-status.projection-temp` recovery
leaf are the only recognized projection transaction artifacts. Both are
descriptor-bound, no-follow, mode/owner/GID/link/size checked; a complete
canonical, zero-byte, or partial crash temp is retired only after repeated
descriptor/basename identity checks and a directory durability barrier; a
swapped, linked, wrong-metadata, or oversized artifact is typed unsafe or
indeterminate and is never broadly cleaned up. Retired temp bytes are not
public status or authority; the retained private projection task republishes
the current target. A successful persistent lock does
not block a fresh authority inventory. If a task observes a genuinely newer public generation, the dispatcher receives
that generation from the same locked writer result rather than reopening the
public leaf, then mints a strictly newer private successor.
The retained compiler-excluded legacy runtime status seam is a no-op; it cannot
write `helper-status` or bypass the projection generation fence.

These are source-level invariants. The remaining proof is runtime-only: an
isolated helper/XPC canary must inject inventory races, PID reuse, process
members, failed status writes, and restart timing before any release-readiness
claim is made.

## Compatibility and packaging

Activation is currently qualified only for macOS build `25F84`. The packaged app includes `CFBundleShortVersionString=0.2.12`, `CFBundleVersion=4`, and helper version `5` under `Contents/Library/LaunchServices`; the installed helper is exposed through the authenticated raw-XPC Mach service, never a lease `WatchPaths` trigger.

Automatic gates build, test, sign, mount, and inspect artifacts without launching the app or changing power state. The live canary is separate.

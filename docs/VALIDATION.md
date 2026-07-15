# Validation

## Automated, no-launch proof

```bash
npm run release:identity:check
npm run release:identity:test
npm run scan:secrets:test
npm run validate:site
```

These portable checks never start the GUI, install the helper, invoke
administrator authorization, or change power settings. Swift compilation and
XCTest are separate release-owner gates launched only through the descriptor-held
entry documented below. Direct wrapper execution and the legacy bundle/DMG
scripts are intentional typed refusals, not passing gates.

### Canonical isolated envelope gate

The sole harmless envelope-Python gate is the following manager-frozen command.
Its final argument is the exact SHA-256 of `script/test_safe_envelope.py` from
this source freeze; the repository pathname is only descriptor-opened and is
never executed before that digest is verified:

```bash
/usr/bin/python3 -I -S -B -c 'import os,sys,stat,hashlib
p=sys.argv[1]; expected=sys.argv[2]; fd=-1
try:
 fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
 before=os.fstat(fd)
 if not (len(expected)==64 and all(c in "0123456789abcdef" for c in expected) and stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and before.st_gid==os.getgid() and before.st_nlink==1 and 0<before.st_size<=8388608): raise SystemExit(74)
 data=bytearray()
 while len(data)<before.st_size:
  retries=0
  while True:
   try: chunk=os.read(fd,min(131072,before.st_size-len(data))); break
   except InterruptedError:
    retries+=1
    if retries>16: raise SystemExit(74)
  if not chunk: raise SystemExit(74)
  data.extend(chunk)
 retries=0
 while True:
  try: extra=os.read(fd,1); break
  except InterruptedError:
   retries+=1
   if retries>16: raise SystemExit(74)
 after=os.fstat(fd); data=bytes(data)
 if len(data)!=before.st_size or extra or (after.st_dev,after.st_ino,after.st_uid,after.st_gid,after.st_mode,after.st_nlink,after.st_size)!=(before.st_dev,before.st_ino,before.st_uid,before.st_gid,before.st_mode,before.st_nlink,before.st_size) or hashlib.sha256(data).hexdigest()!=expected: raise SystemExit(74)
 code=compile(data,"<verified-test-safe-envelope>","exec")
 owned,fd=fd,-1
 try: os.close(owned)
 except BaseException: raise SystemExit(74)
except BaseException:
 if fd>=0:
  owned,fd=fd,-1
  try: os.close(owned)
  except BaseException: raise SystemExit(74)
 if isinstance(sys.exc_info()[1],SystemExit) and sys.exc_info()[1].code==74: raise
 raise SystemExit(74)
try: sys.argv=[p]+sys.argv[3:]; exec(code,{"__name__":"__main__","__file__":p,"__lidswitch_envelope_selftest_sha256__":expected})
except BaseException:
 if isinstance(sys.exc_info()[1],SystemExit) and sys.exc_info()[1].code==74: raise
 raise SystemExit(74)
' script/test_safe_envelope.py 6e13c2d27c2f93cd91f925de1b86d420c94b0cda177acce4280148666854be5a
```

Do not substitute bare `python3`, `/usr/bin/env python`, an Anaconda/interpreter
shim, a direct repository pathname execution, or an invocation missing `-I`,
`-S`, or `-B`: interpreter startup happens before the test can inspect itself,
so a post-start assertion cannot neutralize startup hooks such as `.pth`
processing. The inline bootstrap uses only system Python modules, disables
bytecode output, bounded-reads and re-fstats the no-follow descriptor, then
compiles those verified bytes. The self-test likewise descriptor-loads each
frozen Python dependency; it does not use `SourceFileLoader`, module specs, or
repository `__pycache__`.

Every bootstrap, dependency-loader, and static-audit descriptor failure — open,
bounded payload/EOF probe, EINTR retry exhaustion, re-fstat, digest, compile, or
close — maps to exit `74`. A close is consumed before it is attempted, so a
secondary close failure cannot re-close a potentially reused descriptor. The
outer bootstrap preserves only normal completion and explicit `SystemExit(74)`;
any other namespace `SystemExit` or exception is converted to `74` after its
normal test output has already been written.

Its source-contract assertions read documentation and shell/profile text only as
descriptor-bounded, no-follow audit data; those reads never authorize execution.
This displayed bootstrap is a byte-for-byte audit rendering of the frozen
`CANONICAL_ISOLATED_BOOTSTRAP` literal inside the externally digest-verified
self-test; behavioral fixtures compile only that literal, never documentation
text. The bootstrap-provided self-test digest and the external manager freeze
bind that data to a reviewed source snapshot without creating a recursive
documentation hash dependency.

The explicit runner never calls `unittest.main()`: that API resolves
`sys.modules["__main__"]`, which is the inline bootstrap rather than the private
verified namespace and was the cause of the former false green. It loads only
`SafeEnvelopeProductionFixtures` and requires this exact, unique, lexically
ordered inventory before running:

```text
test_benchmark_app_intake_uses_the_production_private_tmp_capability
test_benchmark_private_tmp_name_boundaries_and_public_intake_are_exact
test_bootstrap_early_eof_and_interruption_regressions
test_explicit_runner_rejects_private_namespace_zero_discovery_and_result_classes
test_production_artifact_capabilities_reject_tree_swaps_and_false_rows
test_production_capture_verifier_round_trip_and_adversarial_mutations
test_production_cleanup_fd_plan_executes_verified_bytes_after_path_swap
test_production_cleanup_snapshot_receipt_rejects_mutable_reexec_authority
test_production_cleanup_state_machine_injected_failures
test_production_parser_corpus_counter_and_swift_order_statistics
test_production_startup_gate_blocks_unbound_payload_and_classifies_release_edges
test_production_supervisor_result_capability_rejects_untrusted_child_exit
test_production_token_bound_process_table_and_signal_selection
test_receipt_status_matrix_and_terminal_call_ordering
test_selected_clt_capability_contract_rejects_inherited_or_alternate_roots
test_trusted_isolated_python_gate_source_contract
```

An authentic gate run prints each of those 16 test names at verbosity 2, then
`Ran 16 tests` and `OK`. Discovery drift, zero tests, duplicate/missing/extra or
renamed methods, a skip, expected failure, unexpected success, failure, or error
terminates with 74; no nominal `OK` is accepted for a partial inventory.

### Held Swift-wrapper launch authority

The release manager's fixed-Python launcher descriptor-verifies its locally
frozen entry and machine-bound held contract before it opens each wrapper, sourced shell dependency,
profile, helper, and source manifest beneath the held repository descriptor.
It then pins `/bin/bash -p`, passes only the fixed descriptor map, and closes
all unrelated inherited descriptors before releasing the startup gate. An
arbitrary repository pathname remains explicitly **not source-credible for
execution authorization**; only this held entry is eligible for the future
focused Command Line Tools test/build. The canonical isolated envelope gate is
still source/fixture evidence, not a runtime or release claim.

Both Swift wrappers now stop before compilation or XCTest unless a wrapper-owned
live-state preflight can classify the host as either the same fresh active
generation or verified safe idle. The preflight reads AC/SleepDisabled and the
public root-owned `helper-status`, captures the installed launchd/helper identity,
and records metadata only for private `0600` authority. It never reads private
authority content. Legacy root evidence may remain root-owned `0600`, `0640`,
or `0644` with the exact wheel/admin group; candidate private evidence remains
root:wheel `0600`. Active preflight requires two full captures separated by one
renewal cadence; status and lease deadlines must strictly advance before Swift
can execute. Active postflight requires the same session UUID and canonical
steady-reason schema, launchd PID/program, unchanged power settings, strictly
advancing status and lease fields whenever another cadence elapsed,
status/lease boot UUID and lease build tied to the current kernel, and
byte-identical static/private metadata. Transitional reasons such as
`reconnect-pending` are rejected. Idle postflight
requires exact safe-idle state. Session replacement, terminalization, helper or
plist drift, private-ledger mutation, and indeterminate reads fail the wrapper.

SwiftPM and XCTest run under `sandbox-exec` with a clean environment, an isolated
`0700` HOME/TMP/cache/execution tree directly under literal `/private/tmp`, and a
tracked fail-closed profile. Every `TestSandbox` fixture is a descriptor-verified
child of that run's exact `fixtures` directory; there is no wildcard permission
to write sibling retained runs. A separate descriptor-pinned `0700` control root
holds the profile, raw captures, and durable receipt; both its literal anchor and
subtree are denied for reads and writes inside the sandbox, so XCTest cannot observe or forge
the outer wrapper's host evidence. The test process cannot read production state,
look up the LidSwitch Mach service, invoke `pmset`, `launchctl`, `osascript`,
`sudo`, `caffeinate`, `systemsetup`, or an installed LidSwitch binary; it also
cannot read live power preferences or reach the power-management Mach services.
It cannot write the repository, obtain authorization rights, create launchd
jobs, use LaunchServices/ServiceManagement/background-task deputies, create a
detached session, or signal unrelated host processes. A host supervisor closes
nonstandard inherited descriptors, observes the complete child session, kills
any survivor, and fails the run if a descendant outlives Swift. The explicit
benchmark contract writes only the fixed internal `benchmark/results.jsonl`;
after successful host postflight, a descriptor-anchored host helper publishes it
with `O_EXCL|O_NOFOLLOW` and durable file/directory sync. The app path must be
canonical and cannot be the installed app, repository, either production support
root, or either wrapper root. The executable wrappers must be invoked only by
the descriptor-held release-manager launch path with its exact local contract.
Those device/inode-bound proof artifacts are intentionally not portable source.
Direct pathname execution, sourcing, or invoking the wrappers as
`bash script/...` is unsupported and rejected. Their privileged-mode shebang
also ignores `BASH_ENV` and imported functions. If
`sandbox-exec` is missing, the wrapper fails closed. Every attempt retains its
execution root and separate control root containing `live-preflight*.kv`,
`live-postflight.kv`, the rendered profile, raw observations, and a create-once,
fsynced `live-state-retained.receipt`; no wrapper cleanup runs.

## Reproducible performance baseline

Current `lidswitch-benchmark-v3` output is fixture-backed snapshot-core work
plus optional explicit artifact observations. It intentionally excludes
`native.power-inspector` scenarios and does not claim native power inspection,
launchctl, or production session behavior. Historical v2 native rows are
separate historical evidence, not v3 output and not directly comparable to v3
fixture/cache scenarios. The v3 status-churn row rewrites a fixture status
record, runs a primed fixture `InspectionEngine` with `reuseIfFresh`, parses
the newest reason/timestamp, and rejects the sample unless it observed exactly
one static-cache hit with zero artifact validation, helper-byte comparison,
child processes, and `needsUpdate == false`.

The no-launch benchmark harness separates three paths: fixture-backed
snapshot-core work in the XCTest host, optional explicit external-app bundle
validation, and optional exact helper-byte comparison. It measures safe fixture
lease, desired-state, status, applied-state, secure-lease, and terminal-ledger
read/write paths. It may construct `PowerController` only with explicit
non-mutating fixture side effects; production effects are never selected. It
never issues, renews, revokes, installs, launches, stops, or natively inspects
a LidSwitch session.

```bash
umask 077
RESULT_ROOT="$(/usr/bin/mktemp -d /private/tmp/lidswitch-benchmark-results.XXXXXX)"
ARTIFACT_ROOT="$(/usr/bin/mktemp -d /private/tmp/lidswitch-benchmark-artifact.XXXXXX)"
/usr/bin/ditto "$PWD/dist/LidSwitch.app" "$ARTIFACT_ROOT/Candidate.app"
# The release manager descriptor-loads the accepted held entry and contract,
# selects the test wrapper, and passes exactly these wrapper arguments:
test \
  --filter LidSwitchTests.BenchmarkHarnessTests/testEnvironmentBenchmarkCommandWritesOnlyWhenExplicitlyRequested \
  --benchmark-output "$RESULT_ROOT/results.jsonl" \
  --benchmark-app-bundle "$ARTIFACT_ROOT/Candidate.app" \
  --benchmark-samples 5
shasum -a 256 "$RESULT_ROOT/results.jsonl"
```

`script/benchmark_baseline.sh` remains only a compatibility argument validator
and exits `64` after validation. It never calls the protected test wrapper by
pathname. The benchmark becomes executable only through the same externally
digest-bound `held_bash_entry.py` plus contract used for every accepted Swift
test run; the manager records those machine-bound hashes with the result.

`--output` and `--app-bundle` are required. Both must use literal `/private/tmp`
(never `/tmp`): output is one new filename in an already-created current-user
`0700` direct child owned by the current UID **and current GID**, while the app is
exactly one safe `.app` leaf within an existing current-UID/current-GID
`0700` direct child (`/private/tmp/<safe-root>/<safe>.app`). Every complete
component uses the ASCII `SAFE_NAME` grammar (1...96 bytes); literal `/private/tmp`
itself is non-symlinked root:root `1777`; the `.app` leaf's
stem is therefore 1...92 bytes. `--samples` is an integer from `5` through
`100`. Neither output/app parent nor app may be a symlink, nested path,
protected root, or canonical-path drift; the app must contain the regular bundled helper. XCTest writes a
wrapper-owned internal file; the outer wrapper alone publishes to `--output`
after a successful host postflight. The caller retains that directory; there is
no guessed app fallback. The JSONL
contains a cold classification, five-or-more warm samples per scenario, and one
summary record per scenario with median, R-7 p95, and sample standard deviation
in monotonic nanoseconds. Native snapshot rows are labeled `native-test-host`;
fixture rows are labeled `fixture`; real artifact rows are labeled
`external-app-artifact`. Test and fixture roots are retained rather than
automatically removed; raw results remain deliberately untracked.

The shell command supplies the XCTest runner through
`LIDSWITCH_BENCHMARK_APP_BUNDLE`; if a benchmark output environment is present
without that explicit app-bundle environment, the runner fails closed. The
retained safe wrapper owns SwiftPM scratch paths; ordinary wrapper runs
leave both benchmark environments absent and omit artifact scenarios.

Before/after comparisons must use the same Mac class, OS/build, AC state,
toolchain/configuration, scratch-path class, fixture payloads, sample count, and
load classification. Retain every valid sample; report invalid samples and host
contention rather than choosing a best result. `snapshot-core` is real snapshot
core work (native IOKit/CFPreferences, `launchctl`, and state-file reads), but
under XCTest `Bundle.main` is the test bundle: it is not production app-bundle
codesign/version proof and does not compare the bundled helper. The explicit
artifact scenarios call the same production `validateBundle(at:)` codesign and
version algorithm against the supplied app and the same exact-byte helper
comparison used by `helperNeedsUpdate`; JSONL records their booleans and
codesign exit code. Store ownership/mode/no-follow/size/parser checks and
fsync/rename publication paths remain exercised. Debug-test operation counters
are process-local only; release builds compile the probe to a no-op and the app
emits no benchmark telemetry.

The `SessionSafetyTests` suite covers:

- explicit current-session acknowledgement;
- acknowledgement just inside and outside the bounded start timeout;
- more than 30 simulated seconds of full-inspection delay with at least four independent renewals;
- monotonic lease-expiry and atomic commit-boundary rejection;
- stale acknowledgement rejection;
- lease expiry, excessive lifetime, and reboot mismatch;
- unplug restoration and no rearm;
- helper terminal-generation replay rejection after unplug and blocked preflight;
- helper and controller override/status drift termination;
- one owned SleepDisabled-only drift recovery with the same session UUID, fresh
  recovery acknowledgement, bounded diagnostics, and no AC-sleep overwrite;
- a second owned SleepDisabled drift terminalizing without rearm;
- release-helper unreadable override probes failing closed without a setter or
  inherited runtime retry loop; synchronization failure is likewise
  indeterminate and retains durable recovery evidence;
- app and helper inspection reading native power preferences without launching
  `pmset`, and an active UI refresh never terminating the heartbeat-owned
  generation from an independently unreadable inspection field;
- helper-ended UI remaining in a restoring state during delayed rollback,
  clearing stale errors after bounded safe-idle proof, and retaining an
  actionable error when the 30-second verification result is still unsafe;
- helper restart after a reserved recovery failing closed, restart after a spent
  recovery retaining the budget, and a new UUID receiving a fresh budget;
- application-owned native Start, Remove Helper, and Quit confirmations: exact
  one affirmative action, cancel/Escape no action, duplicate presentation guard,
  immediate starting state, and fresh-precondition rejection with protection off;
- AC eligibility is independent of display topology, including a single external
  HDMI display in clamshell mode; only the qualified AC/helper/lease contract
  controls session start.
- bounded, structured, owner-only diagnostic history;
- abnormal helper recovery;
- restoration failure retaining applied-state;
- malformed, writable, duplicate, unknown, and symlinked input;
- unknown power and `SleepDisabled` failing closed;
- stale zero baseline rejection;
- crash-only launchd recovery with no polling interval.

## Performance-native UX slices

The frozen v2 `native.power-inspector.snapshot-core` row is historical,
force-fresh test-host evidence only: its recorded warm median/p95 was
183.498/187.888 ms with two `launchctl` child processes and full main-thread
elapsed. It is neither emitted by nor comparable to current v3 candidate output.
Current v3 instead reports fixture-backed `snapshot-forced-fresh` and primed
`snapshot-cache-hit` work, with optional explicit artifact observations. Static
artifact validation has no TTL: it is reused only while its full no-follow
`lstat` fingerprint is unchanged (device, inode, type/full mode, uid/gid, link
count, size, mtime, and ctime). Launchd inspection alone has a 60-second TTL,
and is forced by static fingerprint drift or a `forceFresh` request. Helper-status
parsing stays uncached, while native power, activation-lease, and active-session
truth are not current harness scenarios. Cache-hit counters must show zero child
processes and zero `helper_byte_comparison` operations.

Panel refresh scheduling is asynchronous and coalesced. While checking, the
panel says `Checking current macOS state…`; retained context is informational
only and cannot authorize Prepare, Start, or Remove. Manual Refresh and Start
preflight force fresh inspection. Pending Start presents `Cancel and Restore`
with Cmd-K and the accessibility label `Cancel pending session and restore
system sleep`; cancellation invalidates stale preflight/acknowledgement work,
revokes any issued lease, and converges through verified safe-idle recovery.

Heartbeat safety checks and the eight-second renewal cadence are unchanged.
Only diagnostic persistence is coalesced: structural start/ack/recovery/end
events publish immediately, while routine renewals become a bounded counted
`renew-summary` flushed at most once every five minutes or with the next
structural event. This reduces steady renewal writes by at least 97% without
changing lease validation or termination authority.

Administrator recovery fixtures additionally prove the canonical daemon,
provision, and recovery argv sizes (`13/15/17`), duplicate/unknown argument
rejection, every one-shot token/exit mapping, exact receipt round trips,
timeout/late-receipt reconciliation, install and uninstall source ordering,
native four-key plus AC/battery legacy migration, and Quit refusing to
terminate before exact safe idle. Generated admin scripts are linted by both
`zsh -n` and `sh -n`; the daemon plist is checked with `plutil`.

The source-only legacy migration matrix also covers helper-only and idle-status
history, no-session `migrated-idle`, AC/battery target `0`, equal, restore, and
superseded branches, nil native reads, the second-read mutation boundary,
`0...1440` canonical parsing, `0600/0640/0644` historical modes, four/six-key
and public/unproven schema-2 restore-only records, unknown-root and mutable-stage
inventory rejection, symlink/hardlink/writable/oversize/growth rejection,
one-sided ledger refusal, marked partial-ledger resume, status/terminal lineage,
setter-throw re-entry, proof-published orphan cleanup, repeated observation,
and one-shot dispatch without listener/timer construction. These fixtures are
not counted as executed until the isolated runtime gate is reopened.
Revision-2 source fixtures additionally exhaust the journal phase/disposition
cross-product, canonical 4/6/12/14-key applied-state byte shapes, immutable
proof replay and drift/reason rejection, plus the exact production
root:wheel/root:admin/root:wheel ancestry contract. They remain unexecuted in
the source-only lane.

The ordinary-user live validator never content-reads `applied-state`,
`terminal-generations`, `recovery-reservations`, or `recovery-proof`; these are
private `0600` helper authority. It checks metadata and consumes the public
`helper-status` projection. Exact private content validation belongs only to a
separately authorized root/no-launch gate.

## Gate profiles

## Safe Swift envelope

The build/test wrappers accept only the release manager's descriptor-held launch;
direct wrapper paths and ordinary Bash execution are rejected, including
`BASH_ENV`/`ENV` influence. The wrapper
creates separate control and execution roots, then creates a positive-list source snapshot of
`Package.swift`, `Resources`, `Sources`, `Tests`, the launchd template, and the exact build/test,
validation, CI, and cleanup policy files exercised by XCTest; the sandbox
cannot read the checkout, `.git`, `.codex`, home state, application-support state, or arbitrary
host paths. The descriptor copier opens every component without following links; rejects
symlinks, hardlinked regular files, FIFOs/devices/sockets, unsafe ownership/modes, and metadata
drift; freezes files to `0444` and directories to `0555`; and produces a recursive metadata/content
seal reverified before every launch. The profile denies default access, network/IPC/authority/
persistence deputies, link/clone/rename aliases, writes outside the execution root, and writes to
the nested source snapshot itself.

The held wrapper never accepts an inherited `DEVELOPER_DIR`, never changes global `xcode-select`,
and never accepts a caller-selected toolchain. Release-candidate builds descriptor-seal the fixed
`/Library/Developer/CommandLineTools` root, its root-owned/non-writable ancestors, exact tools, and
the macOS SDK returned only by isolated `xcrun`. Ordinary tests use the already-installed local
Xcode only because Command Line Tools omit XCTest: the wrapper descriptor-seals the exact
`/Applications/Xcode.app/Contents/Developer` toolchain, its root-owned read-only shared runtime
frameworks, macOS SDK, and the exact macOS-platform framework/private-framework/usr-lib roots used
by XCTest, plus the exact `libxcrun.dylib`, Xcode-toolchain `libtool`, platform
`swift-plugin-server`, and XCTest agent, then reasserts every identity before supervised execution.
Tests are compiled with sealed Xcode Swift using `swift build --build-tests`; the resulting exact
execution-root bundle is then run by the sealed XCTest agent. This avoids SwiftPM's separate test
runtime discovery process while keeping both phases inside the same deny-default envelope. The
test lane cannot select another Xcode path, and the release lane never switches away from CLT. No
`xcodebuild`, Apple account, paid license, paid signing, Developer ID, notarization, or caller-selected
toolchain path is required or authorized. The test wrapper fixes `--build-tests`, `--enable-xctest`,
`--disable-swift-testing`, and the sealed Xcode platform framework/module search
roots; callers cannot substitute another test runtime or search path.

The held manager must request `--release-candidate build`; the held launcher alone maps that mode to
the build wrapper, and only the clean Swift child receives `LIDSWITCH_RELEASE_CANDIDATE=1`. Held tests
require ordinary mode and never receive that variable.

Control files are sealed with device/inode/uid/gid/mode/link-count/size/SHA-256 and rechecked
before use and receipt finalization. Sandboxed stdin is `/dev/null`; stdout/stderr are bounded,
exclusive, single-link regular files under the execution root. After stable descendant absence, the
supervisor hashes its still-held capture descriptors, verifies that each retained name still names
that exact descriptor, and creates an exclusive control-root capture seal containing
device/inode/uid/gid/mode/link-count/size/SHA-256 for both streams. The sandbox cannot create or
replace this seal. A fresh parent-shell-only 256-bit key is generated per wrapper and passed only
over a private stdin pipe to the supervisor and later host verifier; it is neither exported nor
available to the sandbox child, paths, receipts, captures, logs, or command line. The supervisor
HMAC-authenticates canonical capture identity/content plus capture name, roots, nonce, source and
profile seals while it still holds the descriptors. It also exclusively creates a
bounded `supervisor-<capture>.result` under the control root before capture descriptors
close. This host-only `0600`, single-link, fsynced canonical capability is HMAC-bound to
the same context/key and states `launched`, the mapped leader exit only when observed,
the supervisor outcome, and whether the capture seal exists. Authentication failure may
produce no result; that is deliberately treated as untrusted evidence. Every host emission and `--print-bin-path` consumption reopens the stream with
`O_NOFOLLOW`, matches the seal identity and digest exactly, and never trusts a pathname alone. The
supervisor installs flag-only HUP/INT/TERM handlers before `Popen`; durable cleanup is spawned
with those signals blocked and installs its handlers before unblocking them. Every leader and
descendant identity is the Darwin kernel `PROC_PIDTBSDINFO` birth token
`(pid, pbi_start_tvsec, pbi_start_tvusec)`, never PID/session text alone. The token is captured
immediately after the fixed startup-gate spawn, refreshed for each process-table candidate, and
re-read immediately before each per-PID signal. That gate is a fixed system-Python image blocked
on a parent-only pipe and cannot call `sandbox-exec` or the Swift payload until the parent has
the exact PID/birth/session/group identity plus its cleanup receipt. Birth-token failure closes
the gate and waits/reaps it without a PID-only signal or authenticated result; release write/close
or post-release identity ambiguity enters the same token-bound cleanup owner before evidence can
be published. A TERM/KILL process-group broadcast is permitted only when a fresh
token-bound leader record proves `pgid == sid == leader.pid`; missing or mismatched tokens send no
signal and classify containment as unproved. One bounded cleanup owner performs every signal,
poll, enumeration, and exception path, retries bounded macOS `ps pid/ppid/pgid/sess` enumeration
to track descendants and reject session escape, waits/reaps the leader, and requires stable absence
before it can publish authenticated child evidence. Enumeration or signal failure never produces
best-effort result evidence: it retains the roots, records no trusted result (therefore wrapper child
exit `256`), starts a clean no-key durable cleanup-only owner when the bounded owner cannot prove
absence, and returns `74`. The parent descriptor-opens/re-hashes the immutable `/private/tmp`
source snapshot and exact `safe_process_supervisor.py` leaf receipt (device/inode/uid/gid/mode/
link-count/size/SHA-256), holds both snapshot-root and leaf descriptors through `posix_spawn`, and
duplicates them to fixed child FDs. The cleanup interpreter runs only a fixed `-I -S -B -c` system
bootstrap, which re-fstats/hashes the inherited leaf before compiling its bytes; the loaded cleanup
then rehashes the retained snapshot-root FD before unblocking signals or signalling a process. No
mutable snapshot pathname is an interpreter input or authority.
Immediately before postflight, receipt publication, captured output
emission, benchmark publication, and bin-path parsing, the host reasserts control-root and
execution-root identity, immutable source snapshot digest, profile seal, and applicable capture
seals and HMAC key/context; any mismatch exits `74` while retaining the roots and truthful receipt state.
Captured output, optional bin-path extraction, benchmark publication, postflight, and final runtime
reassertion all complete before receipt publication. Receipts carry only nonsecret HMAC/context
identifiers; a preserved receipt is impossible if any later capture validation would fail. A status
`74` has a non-preserved failure receipt even when the receipt records equal pre/post host hashes.
Preflight and postflight only set structured terminal outcome/hash/error state; wrappers emit all
diagnostics and complete every fallible action before one terminal receipt attempt. After that final
attempt, they remove traps and perform only their exact exit.
Receipt schema `3` records `child_command_exit` and `wrapper_exit` separately.
`0...255` is permitted only when the authenticated supervisor result proves that
the sandbox leader launched, its mapped exit was observed, its outcome is
`completed`, and the capture seal exists. Decimal `256` means launch never occurred,
the result was absent/stale/invalid, or the leader exit is unavailable or untrusted.
The exact authenticated result-state matrix is: `setup-failed` and `launch-failed`
are only `launched=false`, `leader_exit=none`, `capture_seal=false`; `completed`
is only `launched=true`, an observed `0...255` exit, and `capture_seal=true`;
`interrupted`, `containment-failed`, and `capture-seal-failed` are only
`launched=true`, an observed `0...255` exit, and `capture_seal=false`. Every
other signed tuple is rejected before wrapper outcome mapping. Only an authenticated nonzero completed leader result may produce
`command-failed-host-preserved`; launch/setup/authentication/containment/capture-seal
failure, interruption, and invalid result are unverified `74` outcomes even if a leader
exit was observed. Benchmark publication failure is `0/74`; host drift/final reassert
may retain a known `0...255` or untrusted `256`, always with wrapper `74`.

For both test and build captures (and the optional `bin-path` capture after a
successful build), the exact matrix is: absent/authentication-invalid/stale result,
never launched, and launch failure are `256/74`; a completed sealed leader `0` is
`0/0`; a completed sealed nonzero or mapped signal exit is the same nonzero
child/wrapper pair with host preservation; observed leader exit followed by containment
or capture-seal failure is that observed `0...255` with wrapper `74` and an unverified
outcome; no observed exit is `256/74`. The optional bin-path result becomes the effective
child result only after build-main completed with `0`; otherwise bin-path is not launched.
An HUP/INT/TERM that interrupts the wrapper before terminal finalization exits its signal
status without a terminal receipt claim, because capture/result validation is incomplete.

The current-user-owned retained receipt is **not independently tamper-evident
against an arbitrary same-UID process after wrapper exit**. `O_EXCL`, no-follow,
and durability prove its creation event, making it useful in-process/forensic
retained evidence. Capture its exact bytes and SHA-256 into an external
manager/release evidence ledger immediately on wrapper return; capture HMAC
identifiers provide contemporaneous correlation, but are not offline-verifiable
after the ephemeral key is gone. True offline same-UID-proof evidence requires a
separate trust boundary (for example a root-owned collector or externally
anchored verifier key) and is outside this nonprivileged wrapper.

Benchmark publication nonblocking-opens and descriptor-validates its source and accepts one exact
canonical `lidswitch-benchmark-v3` JSONL corpus: `run`, `methodology`, `environment`; exactly one
cold sample at index `0` for each declared scenario; then exactly `warm_samples` sequential warm
samples for every scenario; then exactly one sorted summary per scenario. All samples share the
run's fixture root and artifact contract. Scenario kind, artifact metadata, bounded counter names,
complete scenario/result-conditional exact counter maps are enforced. Artifact rows are independently
recomputed host-side from a retained no-follow `/` → `/private` → literal sticky `/private/tmp` →
private artifact-root → app/Contents/Info.plist/Library/LaunchServices/helper descriptor chain, a
similarly retained installed-helper ancestry/leaf chain, Info/release identity, and the strict fixed
`/usr/bin/codesign` result. The canonical benchmark app must be a direct private artifact child
under literal `/private/tmp`; every parent, app, and critical leaf identity/content digest remains
held and is re-resolved no-follow immediately before and after codesign. Helper ancestry/leaf
identities and bytes remain held and are re-resolved around byte comparison. Candidate publication requires a successful artifact
contract rather than mislabeling an authentic failure as success. Summaries
are recomputed from sorted Double-equivalent warm samples using the harness's left-to-right R-7
median/p95 and sample-standard-deviation operation order;
the fixed decimal-serialization tolerance is `0.000001 ns`. Duplicate/missing/reordered controls,
samples, summaries, scenarios, keys, values, or noncanonical JSON fail before any destination is
created, closing output as an arbitrary publication channel.

Publication calls `fsync` and macOS `F_FULLFSYNC` on both the created file and retained destination
directory and fails closed on either error. Source inspection does not claim that the qualified
filesystem accepts directory `F_FULLFSYNC`; runtime qualification must probe it before execution
is accepted. An unsupported error requires design revision and independent review, not a silent
durability downgrade.

Live helper status is accepted through explicit state/reason/session/schema/evidence matrices.
Candidate inactive status is no-session migration truth, terminal status is session-bound,
recovery-required reasons are split between global and session-bound sets, and every accepted
canonical row is bound to the current boot plus both continuous-time and wall-time freshness.
An older legacy-v1 inactive row is accepted only as bounded migration residue when its timestamp
is non-future, the legacy helper is directly observed stopped, AC power is safe, and the retained
legacy lease is present and cryptographically parsed as expired; a running helper still fails closed.
Unknown reasons, alternate session shapes, extra evidence keys, noncanonical numbers, stale rows,
and mismatched override evidence fail closed.

This source-only revision does **not** claim runtime semantic proof. After authorization, the
harmless qualified-Mac probe order is: profile parse; snapshot read-denial/positive-read probes;
hardlink/clone/rename denial probes; authenticated capture HMAC/key/replay/substitution, malformed
seal/framing, independent same-size hash versus size/link, Swift-order-statistic, and
app/intermediate-ancestor/Info/helper/installed-helper capability-swap probes via
the descriptor-verified manager bootstrap command above; injected production supervisor fixtures
for pre-spawn interruption, signal-after-spawn identity capture, TERM-ignoring child, enumeration
failure, SIGKILL failure, leader/descendant token reuse, reuse between enumeration and signal,
birth-token lookup failure, durable cleanup repetition, session escape, immutable-cleanup-receipt
drift, and result-write failure; stdio/FD capture
bound; FIFO/device/symlink/hardlink publisher
rejection; `setsid`, double-fork, reparenting, late-child and signal containment probes; then
canonical active/idle/terminal status freshness and two-capture advancement probes. No app, helper,
XPC, launchd, power, install, or live mutation is part of those probes.

### Property-to-proof coverage

| Property | Current proof | Not proved until qualified Mac/runtime work |
| --- | --- | --- |
| HMAC/capture/result schemas, canonical corpus, receipt ordering, intake grammar | Source/static assertions and injected Python fixtures | Actual wrapper, filesystem, and process interaction |
| Descriptor loader, self-test bootstrap, cleanup FD handoff | Source/static assertions and injected Python fixtures | Darwin `posix_spawn` FD/action semantics and race behavior |
| Swift fixture behavior and Raw-XPC integration | Safe Swift fixture tests | Real helper/XPC generation and production authority behavior |
| Selected CLT/profile rendering | Source/static assertions | Actual Command Line Tools identity, Seatbelt enforcement, and compiler execution |
| Birth tokens, signals, timeouts, stable absence | Injected Python state fixtures | `libproc`, sessions, signals, process reuse, and timeout behavior on Darwin |
| Durability/publication | Source/static assertions and fixture tests | Qualified filesystem `F_FULLFSYNC`, rename, and crash-durability behavior |

The Python self-test dynamically exercises only its Python descriptor/parser/
fixture seams. It does **not** dynamically prove Swift, real Darwin process
behavior, actual Command Line Tools identity, Seatbelt enforcement, or `F_FULLFSYNC`.

`native-macos` and `full-release` are blocked future profiles, not current validation claims.
Immutable candidate/DMG qualification is unavailable; `validate_dmg.sh` truthfully refuses rather
than validating an artifact. Harmless source and fixture validation above remains the only current
no-launch evidence, and it does not establish a candidate, DMG, native-macOS, or release verdict.

The controlled live canary is a blocked future manual deployment step, intentionally excluded from
every current gate. Do not run it until immutable candidate/DMG qualification exists and an
independent release decision authorizes it. Before manually starting the candidate, a manager must
run `script/candidate_canary_preflight.py preflight` against the canonical immutable-candidate-v3
manifest and its separate canonical `lidswitch-candidate-canary-v1` binding. That binding is the
candidate-lane integration seam: it names the manifest SHA-256/candidate ID plus the installed app
executable and helper paths, SHA-256 values, CDHashes, qualified system build, and helper version.
The v3 manifest itself remains strict and is not additively edited for this purpose.
`make-binding` refuses an `app-captured` manifest: it requires `package-captured` or `qualified`,
the supplied bundle identifier must equal `manifest.app.identifier`, the observed app CDHash must
equal `manifest.app.cdhash`, and the observed helper SHA-256/CDHash must equal the manifest helper.

The preflight is observation-only apart from its create-once receipt: it verifies the bound app and
helper identities, no running LidSwitch process, the exact public no-session state (`inactive` with
reason `legacy-migration` or `legacy-migration-superseded`), AC power, `SleepDisabled=0`, the current
AC and battery sleep settings, and one explicit lid-open observation. The preferred autonomous mode
is `--lid-open-observed programmatic-ioreg`: it runs only
`/usr/sbin/ioreg -r -k AppleClamshellState -d 4`, requires exactly one unambiguous
`"AppleClamshellState" = No` row, and binds the raw observation SHA-256 into the canonical v2
receipt. `--lid-open-observed human-confirmed` remains an explicit manual fallback and is labelled as
such in the receipt. Closed, missing, malformed, or duplicate programmatic observations fail closed.
The manager supplies three
new receipt paths: the safe-idle preflight receipt and new active/final receipt destinations. The
preflight also requires the known absent applied-state path, so a stale applied-state record fails
safe-idle rather than being treated as an unrelated artifact. The live script re-reads the same
manifest/binding and re-verifies the installed app/helper digest/CDHash before binding the exact
active session UUID and again before finalization. It creates the final receipt only after its
existing SIGKILL rollback, applied-state disappearance, terminal peer-process-invalid, and no-rearm
checks succeed.

Create the binding once from manager-owned absolute paths and explicit bundle identity before the
safe-idle preflight. This command only reads the candidate manifest, helper-version file, system
build, and installed app/helper signatures and bytes; it neither installs nor starts the candidate.

```bash
/usr/bin/python3 -I -S -B script/candidate_canary_preflight.py make-binding \
  --candidate-manifest /absolute/candidate-manifest.json \
  --binding /absolute/new-candidate-canary-binding.json \
  --app-bundle /Applications/LidSwitch.app \
  --helper '/Library/Application Support/LidSwitch/Current/LidSwitchHelper' \
  --helper-version '/Library/Application Support/LidSwitch/Current/helper-version' \
  --bundle-identifier com.johnsilva.LidSwitch \
  --executable-relative-path Contents/MacOS/LidSwitch
```

It requires `LIDSWITCH_CONTROLLED_CANARY=1`, qualified build `25F84`, AC power, a successfully bound
lid-open observation, a verified active session, and those preflight/receipt paths:

```bash
LIDSWITCH_CONTROLLED_CANARY=1 \
LIDSWITCH_CANARY_PREFLIGHT_RECEIPT=/absolute/preflight.json \
LIDSWITCH_CANARY_ACTIVE_RECEIPT=/absolute/active.json \
LIDSWITCH_CANARY_FINAL_RECEIPT=/absolute/final.json \
LIDSWITCH_CANARY_CANDIDATE_MANIFEST=/absolute/candidate-manifest.json \
LIDSWITCH_CANARY_BINDING=/absolute/candidate-canary-binding.json \
./script/validate_live_state.sh
```

The script observes at least 40 seconds of fresh acknowledgements (`LIDSWITCH_LIVE_OBSERVATION_SECONDS`, minimum `40`), sends `SIGKILL` to the app, waits up to 45 seconds for verified restoration, and proves there is no automatic rearm. A later human-observed unplug/replug and short lid-close test completes local deployment qualification.

To exercise the candidate's same-session recovery path, add the separate
`LIDSWITCH_INJECT_OVERRIDE_DRIFT=1` opt-in. It first verifies the helper owns a
current AC session, invokes only `sudo pmset -a disablesleep 0`, and waits at
most 10 seconds for `SleepDisabled=1`, AC sleep `0`, a fresh `active`
`override-recovered` status, and the unchanged session UUID. It never edits
root state files. Do not run this on a production session unless the explicit
canary is intended.

## Public surface

```bash
npm run validate:site
npm run public:hygiene
npm run scan:secrets:test
node scripts/scan-public-secrets.mjs
```

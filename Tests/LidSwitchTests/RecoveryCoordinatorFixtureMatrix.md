# RecoveryCoordinator deterministic fixture matrix (source-present, unrun)

These fixtures are intentionally source-only while the runtime safety gate is
closed. Each fixture uses an owned temporary directory capability, a fake
`HelperPowerSystem`, and transaction fault seams; it never targets the live
helper, launchd, XPC, or `pmset`.

| Fixture | Deterministic assertion |
| --- | --- |
| pristine bootstrap | private empty ledgers plus `pristine/bootstrap` proof and no applied record returns `pristineIdle` |
| missing / unsafe lock | no transaction body and no power setter call; result is `recoveryRequired` |
| held-lock timeout | no transaction body and no power setter call |
| schema-2 reconnect | normal startup yields only `reconnectCandidate`; recover-once terminalizes it |
| legacy record | can restore listed fields but never yields a reconnect candidate |
| v0.1 no UUID | strict history produces `migratedIdle`, `session=none`, and never pristine or a synthetic generation |
| old writers live/unproven | only explicit lock provision may mutate; daemon observation publishes no ledger, proof, journal, status, or power change |
| strict root inventory | unknown leaves and canonical mutable administrator stages fail closed; a canonical receipt is diagnostic only |
| production ancestry | only root:wheel `/` + `/Library`, root:admin `Application Support`, and root:wheel final LidSwitch at exact `0755` across all `07777` bits are accepted; wrong path/type/owner/group/mode and setuid/setgid/sticky fail |
| historical metadata | root wheel/admin `0600/0640/0644` is restore input only; links, writable modes, oversize, growth, and unsafe ancestry fail |
| timer decision table | `T=C`, `C=0/T>0`, positive supersession, `T=C=0`, `T=0/C>0`, nil fields, and `0...1440` bounds are exact |
| mutation-boundary reread | a positive timer appearing after planning is preserved and no setter runs |
| legacy status lineage | only canonical inactive/no-session or exact latest terminal lineage can migrate |
| legacy applied schemas | four/six-key and public/private unproven schema 2 are downgraded to private restore-only state |
| public schema-2 downgrade | proof-absent or explicit recovery-required retry strips owner/lease before private publication; crash state remains restore-only and daemon cannot reconnect |
| public schema-2 proof conflict | migrated/pristine/terminal proof plus public applied bytes publishes nothing, preserves proof/evidence, performs no setter, and remains non-reconnectable |
| canonical applied bytes | documented 4/6/12/14 shapes require exact order, lowercase UUIDs, canonical numbers, one final newline, and no blank/extra fields |
| partial empty ledgers | only an exact pristine proof, legacy applied record, or legacy journal may resume its own one-sided publication |
| legacy crash journal | pre-setter, setter-throw-after-mutation, native-safe, proof-published, quarantine-unlink, and cleanup re-entry never rearm |
| journal phase matrix | prepared targets are pending, absent targets are not-required, safe dispositions are possible/canonical, and invalid cross-products reject |
| superseded range | only canonical `superseded-1...1440` differing from target parses; current zero with a positive target fails closed and retains proof/journal/evidence |
| proof-before-journal crash | matching migrated proof/native-safe journal completes without proof rewrite; reason or native drift preserves immutable evidence and fails closed |
| sleep / AC / both | only the explicitly changed fields are restored and postcondition matches exact original AC |
| malformed / duplicate / truncated ledgers | no setter call and `recoveryRequired` |
| battery / unknown / nil field | no setter call and `recoveryRequired` |
| publication uncertainty | terminal/proof `publishedButUnverified` preserves applied record and returns `recoveryRequired` |
| removal uncertainty | proof remains durable, applied record remains quarantined/evidenced, and result is `recoveryRequired` |
| crash gaps | terminal-before-power, power-before-proof, proof-before-status, status-before-removal all re-enter without rearm |
| repeated recovery | second call observes exact terminal proof and performs no setter call |
| one-shot dispatch | provision/recover-once do not construct listener or reconciliation timer |
| bounded Darwin argv adapter | `ContainedProcessRunnerFixtureTests.testKernelProcargsAdapterRejectsMalformedAndEnvironmentSuffix` covers valid/padded argv, malformed argc/NUL boundaries, argc bound, and ignored environment suffix; live `sysctl` payload/race proof remains open |
| suspended receipt handoff | `ContainedProcessRunner.runSpawned` persists an exact leader receipt before `SIGCONT`; source fixtures cover receipt phase/latches, but an isolated Darwin spawn/sink-failure canary remains open |
| containment transfer / restart | `testReceiptKeepsEachRecordedMemberExecutableAndArgvBinding` proves member-specific birth/executable/fingerprint serialization; accepted receipt owner CAS does not steal live owners, reclaims expired owners, and never rewinds KILL to TERM. Unbound later members fence rather than inherit a fingerprint |
| containment owner lease / reap | `testContainmentClaimCarriesItsLeaseDeadlineIntoActualStoreTransition` uses the production store claim/CAS path with the claimed deadline; `testExpiredUnprovenLeaderReapFencesExactlyOnce` drives the receipt/reap reducer through ECHILD, owner deadline, one ambiguous retained fence, and no removal proof. The queued scheduler call graph is source-inspected; isolated queue timing remains runtime proof |
| containment extinction | TERM then persisted KILL then reap clears only after two stable empty inventories; early reap is allowed only with exact empty proof |
| containment ambiguity | reused PID, new member, PGID/SID mismatch, unreadable inventory, bounded EINTR/ECHILD, deadline, and stale CAS retain the fence, issue no second signal, and project `containment-extinction-unproven`; `testProductionLeaderReapAdapterRetriesEINTRAndNeverTreatsECHILDAsProof` drives the production waitpid loop seam |
| inventory capacity race | `testInventoryAdapterRejectsFullBufferAndSizeRace` covers the production adapter's enlarged-capacity/full-buffer/size-race predicate; live Darwin inventory timing remains runtime proof |
| status projection task | exact canonical task carries authority snapshot/generation/session/reason digest, attempt/deadline/next-attempt and token CAS; `testProjectionGenerationWatermarkSurvivesTaskRemoval` proves root-private generation remains strictly increasing after dirty-task deletion; malformed/stale task is retained fail-closed |
| status projection dispatch | `testStatusProjectionTaskIsBoundedCanonicalAndRetryIsStatusOnly` covers retry cap and boot rebase; `testStatusProjectionWriterSerializesNewGenerationBeforeOldRetry` calls the production descriptor-held writer on an owned fixture file and proves newer generation survives old retry; the stale generation travels in that locked writer outcome, not a second reopen. `testStatusProjectionWriterVerifiedSwapPublishesOnlyNewerGeneration` drives the descriptor-relative verified swap; `testStalePublicGenerationMintsNewInitialAcknowledgementTask` proves a stale public generation mints a strictly newer root-private initial acknowledgement; `testStatusProjectionWriterRetainsMalformedPublicLeafAsUnsafe` retains malformed public bytes as `unsafeExisting`; `testStatusProjectionProductionWriterFaultGateLeavesNoPowerOrLeaseSideEffect` invokes each production writer open/write/fsync/full-sync/rename/reopen/close fault gate. Crash-temp and fresh-start behavior remains source-inspected until its isolated file-system fixtures run |
| projection isolation | retry causes zero power setter, lease renewal/extension, authority/session creation, XPC listener, or containment-queue action |
| connected one-time repair | `testConnectedTickSpendsOwnedRecoveryBudgetOnceAndRestartFencesRearm` creates the production `HelperSessionAuthority`, begins an authenticated connected session, drives `reconcileForTesting()` through `tickLocked` and `privateAuthorityMatches`, proves `reserved` -> one `sleep=1` setter -> native verification -> `spent` plus recovered projection, then recreates/hydrates/reconnects the authority and proves a second owned drift terminalizes with zero setter/rearm |

The source fixtures are deliberately unrun while the isolated test surface is
closed. Rows explicitly identify remaining fault-injection and live-Darwin
gaps; none is runtime or canary validation.

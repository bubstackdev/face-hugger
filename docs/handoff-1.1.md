# Face Hugger 1.1 development handoff

Updated October 27, 2026. The user asked to capture the session and stop for now. Resume implementation or release work only when asked. The 1.1 feature work is implemented through the pairings and folder-entry milestone; release verification is incomplete. Nothing from these sessions was installed, distributed, submitted, or released.

## Start here next session

1. Read this file, [the implementation status](plan-1.1.md#implementation-status), and `git status --short` before changing anything. The user explicitly requested committing the complete working tree at shutdown. The implementation and this handoff are captured together under the commit subject `Implement 1.1 upload workflows and capture development handoff`; inspect `git log` for its hash. Preserve any subsequent modified or untracked files; do not reset, clean, or replace the tree.
2. Read the four verification records linked below. They distinguish synthetic/core checks from signed sandboxed and live-service evidence.
3. Continue with signed sandboxed interaction and release verification, rather than starting another feature or migrating Aether Kit. Use isolated test state so real pairings, queue, Keychain credentials, and receipts are not overwritten.
4. Obtain specifically scoped authorization before live writes if none is present in the resumed session. Do not use the retained App Review repository as a disposable fixture. Historical authorizations in old handoffs are context, not a reason to infer new authorization.
5. Recheck current tools, signing identities, profiles, and Store state before using them. No App Store Connect readback was performed during the 1.1 sessions.

Workspace: `/Users/zakkeown/Code/bubstackdev/face-hugger`. Branch at handoff: `main`. The pre-implementation HEAD was `cac29ba` (`Security baseline: pin actions to commit SHAs, read-only token, ignore keys and credentials`). The shutdown commit captures all 1.1 work; no PR, push, or release was requested or performed.

## Agreed scope

The [roadmap](roadmap.md) and [1.1 plan](plan-1.1.md) are the source of truth. Version 1.1 covers complete upload review, clearer progress/recovery, durable receipts, saved pairings, and Dock folder entry. Keep macOS 15 minimum, universal packaging, the existing Transfer Bench design, and one active upload worker. Start/Resume remain user controlled.

Aether Engine and Aether Kit are distinct. The user is handling Aether Kit improvements separately; importing `/Users/zakkeown/Code/bubstackdev/aether/aether-kit` is outside this 1.1 implementation. Do not add that dependency as an assumed next step. Version 2.0 is oriented toward local–Hub projects and repeatable ML publishing. Downloads, bidirectional sync, branch/tag UI, scheduling, parallel workers, bandwidth controls, and partial multipart resume are outside 1.1.

## Implemented code and contracts

### Attempts and durable history

- [TransferHistory.swift](../Sources/FaceHuggerCore/TransferHistory.swift) provides typed ordered attempt reduction, recording, versioned archives, redacted failure summaries, and shareable receipts. Native events no longer round-trip through legacy JSON lines for UI updates.
- Attempt creation is persisted before execution. Confirmed commits checkpoint synchronously before uploader recovery state advances. Persistence errors stop/pause further work and surface an error. Finalization is idempotent; unfinished receipts recover as interrupted without an invented finish time or success.
- Retain the newest 200 terminal receipts plus the active attempt. Each retains its last 20 commit references and full acknowledged file/commit counts. Old queue history imports once, leaving unrecorded measurements unknown.
- Queue removal removes its recovery state/plans but leaves history. Clear history only clears terminal receipts. Receipt copying omits absolute source paths, bookmarks, tokens, signed URLs, file bodies, and session logs.
- App wiring: [AppModel.swift](../Sources/FaceHugger/AppModel.swift), [TransferHistoryView.swift](../Sources/FaceHugger/TransferHistoryView.swift), and [TransferShelf.swift](../Sources/FaceHugger/TransferShelf.swift).

### Complete review and guarded execution

- [UploadSource.swift](../Sources/FaceHuggerCore/UploadSource.swift) shares bounded reads, file stamps/mutation checks, raw SHA-256, and framed Git blob SHA-1/SHA-256. Legacy checkpoint encoding remains compatible.
- [UploadPlan.swift](../Sources/FaceHuggerCore/UploadPlan.swift) uses a full private SQLite inventory with bounded pages. The 2,000-row preview cap does not cap planning. Plans distinguish add, replace, identical, excluded, needs comparison, and conflict. LFS content hashes, Git blob IDs, and opaque Xet metadata stay distinct. Size alone never proves identical content.
- Approval binds source, account, repository visibility, destination, filters, and revision. Unknown comparisons require a separate explicit acknowledgement. Review hashes locally and reads remote metadata; it does not negotiate content, upload objects, or commit.
- [ReviewedUploader.swift](../Sources/FaceHuggerCore/ReviewedUploader.swift) revalidates the complete included source set and remote/account context, executes only approved rows, skips verified identical content, and guards each commit with its expected parent. Acknowledged batches atomically advance completed paths and expected revision in the plan. Foreign/ambiguous commits require fresh review; no automatic commit replay.
- All-identical completion records a verified revision without claiming a new commit. Repository-ignored files have separate counts. Older jobs without a plan first open review; reviewed jobs can be reviewed again.
- **Known limitation:** repositories without a confirmed revision produce a blocked review. Initial-commit execution needs separate validation of the service precondition; do not introduce an unguarded fallback. An initialized repository with a confirmed revision and an empty tree is supported.
- UI: [UploadReviewWorkspace.swift](../Sources/FaceHugger/UploadReviewWorkspace.swift) and [UploadReviewView.swift](../Sources/FaceHugger/UploadReviewView.swift). Preserve the status-only `UploadPlanBuilder.build` overload: an added default closure initially broke trailing-closure binding, so the phase-aware overload requires `onPhase` explicitly.

### Transfer activity and retry visibility

- [TransferActivity.swift](../Sources/FaceHuggerCore/TransferActivity.swift) defines phases, sanitized request events/retry categories, raw transport totals, a bounded monotonic rate window, and Retry-After parsing. [NativeHub.swift](../Sources/FaceHuggerCore/NativeHub.swift) observes both file-backed and data-backed URLSession upload bodies, including actual final task body counts.
- Logical file progress is separate from observed request-body bytes. Body totals include metadata, encoded commits, and observed explicit retry sends; a separate subset covers file/commit bodies. They exclude headers, transport overhead, and any claim to count TCP retransmissions or remote acceptance. High-water marks prevent duplicate/decreasing callbacks from double counting; stale request/attempt callbacks are ignored.
- Rate uses at most 64 monotonic samples around five seconds, requires 250 ms of observations, and expires after two idle seconds. It clears on request completion, suspension, waits, and terminal outcomes. Small requests may never display speed. There is no fabricated overall ETA.
- Eligible requests retain a three-attempt cap, production one/two-second backoff, and Retry-After integer/HTTP-date handling capped at 30 seconds. Commits and multipart completion are not automatically retried. Authentication/permission errors and conflicts do not retry. Waits are cancellable; scheduled waits and retries actually started are separate metrics.
- Receipts persist raw totals/retry summaries and last phase/activity time at control/commit/terminal checkpoints. They do not persist live rate, current file name, request IDs, or countdown deadlines. A crash can lose observations after the last checkpoint. Old archives decode new fields as unknown.
- [TransferActivityView.swift](../Sources/FaceHugger/TransferActivityView.swift) shows phases, current file, measured speed, and retry countdowns. The shelf's existing Stop remains available during waits. AppModel samples snapshots every 100 ms, including idle rate expiry when event sequence has not changed.

### Saved pairings and folder entry

- [Pairing.swift](../Sources/FaceHuggerCore/Pairing.swift) adds defaulted pin/order fields, stable ordering, multi-term route search, live resolved device/inode folder identity, and an active binding to source/repository/destination/filters. Rename preserves identity and route. Manual divergence clears activation; reverting fields does not automatically reactivate it.
- [SavedPairingPicker.swift](../Sources/FaceHugger/SavedPairingPicker.swift) provides search, active/pinned indication, rename, pin, move within pin group, removal, and the multi-folder chooser.
- [FolderEntry.swift](../Sources/FaceHuggerCore/FolderEntry.swift) captures and owns security-scoped entries before deferred UI, deduplicates folder identities, and refuses mixed files/packages/nonlocal URLs. Symlink bookmark creation initially failed in Foundation: capture now holds the original grant while bookmarking the resolved target, independently restores that bookmark, then releases the original grant. Core tests cover this; repeat in a signed sandbox.
- AppModel shares picker/drop/open-event staging. Existing workspace replacement needs confirmation, editors/reviews block replacement, and reentrant open events cannot override a confirmation prompt. A folder retains the current destination/filters; a pairing supplies its route. Neither starts an upload or alters queued/running jobs.
- [FaceHuggerApp.swift](../Sources/FaceHugger/FaceHuggerApp.swift) captures cold-launch events before model attachment and uses a scene-scoped `openWindow` action for warm reopening. Pending access lives until delivery/selection. [Resources/Info.plist](../Resources/Info.plist), included by [project.yml](../project.yml), registers `public.folder` as alternate Viewer; Store configuration inherits it. Do not make Face Hugger the default folder handler.

## Latest verification

| Check | Result and scope |
| --- | --- |
| `Scripts/check.sh --build` | Passed: 64 XCTest plus 65 Swift Testing tests, 129 combined; Python 56 run with 3 skipped; native Debug app built |
| Universal Release | Built for arm64 and x86_64; `lipo` verified each slice; both report macOS 15 minimum; strict ad hoc signature verified |
| Real URLSession loopback | Synthetic 65,536-byte inline and 2,097,152-byte file bodies; server/delegate counts matched; no Hub or credentials |
| Native cold/warm entry | Actual app scene/delegate source with stub model/view and unique temporary bundle ID; cold folder delivered once, first window closed, warm folder delivered and window visibly reopened; harness quit |
| Visual checks | Actual SwiftUI receipt/review/activity/pairing/chooser components with synthetic data; light/dark previews inspected; no real queue or Keychain loaded |
| Final formatting | `git diff --check` passed; changed documentation file links resolve |

Read [foundation verification](verification/1.1-foundation.md), [upload review verification](verification/1.1-upload-review.md), [transfer activity verification](verification/1.1-transfer-activity.md), and [pairings and entry verification](verification/1.1-pairings-entry.md). Earlier test counts in those dated records are historical, not contradictory to the final 129.

Useful ignored local evidence, which may disappear on a clean build:

- `.build/pairings-entry-check.log` is the final complete regression/Debug build log.
- `.build/one-one-universal-build.log`, `.build/one-one-universal-inspection.log`, and `.build/one-one-universal/Build/Products/Release/Face Hugger.app` cover universal development Release validation.
- `.build/pairings-entry-preview/` contains `Preview.swift`, light/dark PNGs, `DockSmoke.swift`, `dock_smoke.py`, `dock-smoke.log`, and `Folder Entry Smoke.app`. The Dock smoke compiles the actual `FaceHuggerApp.swift` against a stub AppModel; it does **not** test the real AppModel's prompts or persistence.
- `.build/transfer-activity-preview/` contains synthetic render and loopback harnesses/logs. `.build/upload-review-preview/` and `.build/one-one-preview/` contain earlier UI fixtures.
- Prior slice logs: `.build/upload-review-check.log` and `.build/transfer-activity-check.log`.

The App Intents metadata-extraction warning is the existing missing-AppIntents-dependency warning. No new test/build failure remains at handoff. The latest handoff edits themselves are documentation only.

## Remaining release work

1. Exercise the **real signed sandboxed app**: review/approve/cancel; unknown/conflicting/stale plans; active pairing changes; rename/pin/order; picker/drop and cold/warm Dock; multi-folder cancellation; editor/review protection; external/moved folders, symlinks, permission refusal, and fresh-process bookmark restoration. Offscreen previews and the nonsandboxed entry harness do not establish these results.
2. Check keyboard navigation, accessibility/VoiceOver, confirmation/menu actions, long names, large counts, and both appearances interactively.
3. With specifically authorized disposable Hub fixtures, verify reviewed uploads and hashes, server reuse, partial commit stop/relaunch/resume, stale parent/account/visibility refusal, all-identical no-op, repository ignore, retry waits, and cancellation. Preserve confirmed evidence and clean only the authorized disposable resources. No live Hub mutation was performed in these 1.1 sessions.
4. Run on actual macOS 15 and actual Intel hardware or an appropriately identified execution environment. A universal binary is not Intel execution evidence.
5. Build and audit the exact signed Release app/installer, including entitlements, privacy manifest, weak linking, installed-bundle contents, recovery/migration, and native-only dependencies. Do not reuse an older package audit for changed code. Choose version/build metadata deliberately; development `project.yml` remains 0.1.0 (1), and inherited Store metadata remains 1.0 (7), not a prepared 1.1 release.
6. Reconcile release documentation and current Store state before packaging/submission. The historical [handoff](handoff.md) records build 7 attached on October 12; README still describes build 6. Neither is a current ASC readback. Preserve prior release evidence and keep 1.0 listing work distinct from the 1.1 development changes. Submission/release is not authorized by a request to continue coding.

## Commands and environment details

From the workspace root:

```sh
Scripts/check.sh --build

xcodebuild -project FaceHugger.xcodeproj -scheme FaceHugger \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build/one-one-universal \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
```

`Scripts/check.sh --build` runs Swift, historical Python, XcodeGen, and Debug build. XcodeGen regenerates the tracked project; preserve new source inclusion and the Info.plist setting. Store builds use `project-store.yml` and the existing packaging/audit scripts, not this ad hoc Release command.

In this session the configured writable cache root `/Users/zakkeown/Library/Caches/coreai-cache` is a symlink to `/Volumes/Scratch/coreai-cache`, preventing the default exec sandbox from starting. Shell commands used `sandbox_permissions: require_escalated` with concrete justifications and passed automatic review. `apply_patch` worked directly for repository writes. Reassess the environment next session; do not request blanket access or edit the symlink merely to work around it.

No repository `AGENTS.md` was found in the relevant ancestor/repository searches. The active developer instructions prohibit spawning subagents unless the user or an applicable instruction explicitly requests them; none were spawned for this 1.1 work. Do not treat an old handoff's general subagent approval as overriding current instructions.

No new scheduled automation, background upload, or persistent server was created. The loopback server shut down and the isolated native entry harness quit. Keep real app processes and user state untouched when resuming.

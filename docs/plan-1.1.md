# Face Hugger 1.1 implementation plan

Planning started October 27, 2026. The scope follows the [agreed roadmap](roadmap.md#version-11).

Version 1.1 makes the upload workflow understandable before, during, and after a transfer. The release should answer three questions: what will change, what is happening now, and what actually completed?

## Scope and working decisions

The release includes full upload review, phase and retry visibility, durable transfer receipts, saved-pairing improvements, and Dock folder entry. Keep macOS 15 as the deployment target and retain universal packaging. Preserve the existing Transfer Bench layout and one active upload worker.

Aether Kit migration, downloads, bidirectional synchronization, branch/tag UI, scheduled or post-quit transfers, parallel workers, bandwidth controls, and partial multipart recovery are outside 1.1. The current dataset-card feature continues independently. User-controlled Start/Resume and the current bounded request retries remain the recovery policy; this release does not add an unlimited job restart loop.

## Existing foundations

This table records the 1.0 starting point. The implementation status below tracks the 1.1 changes.

| Current behavior | Source | Work needed for 1.1 |
| --- | --- | --- |
| Folder scanning and in-window URL dropping | [Staging.swift](../Sources/FaceHugger/Staging.swift), [MainView.swift](../Sources/FaceHugger/MainView.swift) | Reuse staging for Dock entry and consistent replacement prompts. |
| Path comparison and complete upload conflict preflight | [NativeComparison.swift](../Sources/FaceHuggerCore/NativeComparison.swift), [NativeUploadPathIndex.swift](../Sources/FaceHuggerCore/NativeUploadPathIndex.swift) | Add revision-bound content comparison and a complete, disk-backed review plan. |
| Remote tree entries contain path, size, and type | [NativeHub.swift](../Sources/FaceHuggerCore/NativeHub.swift) | Preserve supported content identities and revision information. |
| Sequential hashing, file-backed upload, and confirmed-file checkpoints | [NativeUploader.swift](../Sources/FaceHuggerCore/NativeUploader.swift) | Share file identity logic with planning, execute approved actions, and expose structured results. |
| Up to three attempts for eligible reads, negotiation, and idempotent uploads | [NativeHub.swift](../Sources/FaceHuggerCore/NativeHub.swift) | Expose attempt/wait events and keep non-idempotent commits outside automatic replay. |
| Native events are translated into legacy JSON lines for UI updates | [AppModel.swift](../Sources/FaceHugger/AppModel.swift) | Introduce an ordered typed reducer for metrics and history; derive display logs from events. |
| Jobs survive relaunch; in-memory logs and progress do not | [Models.swift](../Sources/FaceHuggerCore/Models.swift), [AppModel.swift](../Sources/FaceHugger/AppModel.swift) | Add versioned attempt summaries and receipts without inventing legacy measurements. |
| Pairings persist source bookmarks, destination, and filters | [Pairing.swift](../Sources/FaceHuggerCore/Pairing.swift) | Add backward-compatible pin/order fields, rename/search UI, and active pairing tracking. |

The current uploader's private per-file receipts are recovery checkpoints. User-facing transfer receipts are a separate durable history feature.

## User workflow

1. Choose/drop a folder or open it through the Dock, then choose a repository or saved pairing.
2. Select Review upload. Metadata comparison and local hashing prepare a full change plan, with progress and cancellation. Review may read local file contents for hashes; it sends no file contents and performs no object upload or commit.
3. Review additions, replacements, verified identical files, exclusions, unknown comparisons, and blocking conflicts. Confirm Upload or Add to queue.
4. Before execution, validate the source identity, destination, account context, visibility, and expected remote revision. A stale plan requires refreshed review. A queued job may therefore need review again when another job changes the same repository.
5. Show phases, measured transfer activity, commit confirmations, and bounded retry waits. Stop cancels current work and waits for it to settle.
6. Retain a receipt for completion, failure, stop, or interruption. Resume creates a new attempt under the same job and revalidates its plan and recovery state.

## Upload plan contract

Use one disk-backed plan for the entire filtered file set; the existing bounded preview is a window onto it. Keep memory bounded during local enumeration, remote pagination, hashing, and execution. Share filtering and file-identity rules with the uploader to prevent preview/execution drift.

Each plan records a schema version, plan/job identity, source fingerprint, repository kind/name, destination, filters, account identity without credentials, visibility, expected remote revision, creation time, and per-file action with evidence. Proposed implementation types are `UploadPlan`, `UploadPlanStore`, `UploadPlanBuilder`, and `PlannedFileAction`; these names are design proposals.

| Action | Required evidence and behavior |
| --- | --- |
| Add | A complete comparison at the selected revision establishes that the destination path is absent. |
| Replace | The path exists and comparable content identity establishes a difference. |
| Identical | Local content identity matches a supported remote identity at the selected revision. Skip transmission and unnecessary commits. |
| Excluded | A local filter excludes the file. Record repository ignore decisions separately when negotiated after upload approval. |
| Needs comparison | The path exists but comparable content identity is unavailable. Explain that uploading may replace it; explicit approval can include this action. |
| Conflict | A file/folder collision or invalid path blocks execution until resolved. |

An incomplete remote listing does not produce an executable complete plan. Missing hashes never establish equality; file size alone never establishes identical content. Keep Git blob identities, LFS content hashes, and other storage identifiers distinct. Support only identity comparisons verified by fixtures; preserve unknown for everything else.

Planning should reuse the uploader's bounded file reads and mutation checks. Hashes may be cached only with a validated file identity; source contents stay live and changes invalidate the reviewed plan. An all-identical plan finishes as verified with no changes and no new commit.

Separate candidate file-content bytes from actual request-body bytes. Before service negotiation, describe planned upload content size as an estimate and identify unknown comparisons or repository rules. Service reuse and encoding overhead mean it is not an exact network-byte promise.

Bind tree reads to the reviewed revision and guard each commit against the expected parent. Acknowledged commits made by this attempt advance that parent. A conflicting writer requires refreshed review; checking the head before a request alone does not close the race. Keep batches explicit: several confirmed commits do not form a whole-folder atomic transaction.

Hugging Face documents Git blob IDs, optional LFS metadata, and a `parent_commit` precondition that rejects a commit when the target revision has moved. Validate the corresponding HTTP fields and revision-scoped pagination in milestone 0 before implementing skip or guarded execution. See the official [RepoFile reference](https://huggingface.co/docs/huggingface_hub/package_reference/hf_api#huggingface_hub.RepoFile) and [create_commit reference](https://huggingface.co/docs/huggingface_hub/package_reference/hf_api#huggingface_hub.HfApi.create_commit).

## Progress and recovery contract

Introduce typed events for scanning, comparing, hashing, uploading, committing, retry wait, and terminal outcome. Attach job ID, attempt ID, sequence, timestamp, and relevant file/request identity. Reduce them once in order; delayed callbacks from an earlier attempt cannot mutate a newer attempt or duplicate history. Coalesce frequent UI updates while preserving commit and terminal events.

Track logical file-content progress separately from observed HTTP request-body bytes. Retries may send the same bytes again; reused objects may send no file body. Inline content, encoded commit bodies, and LFS bodies need explicit accounting. Preserve raw integers and durations; format them only at the UI boundary.

Display speed from observed upload-body activity over a monotonic time window. Reset or suspend that sample across attempts and retry waits. Phase counts remain separate. An overall ETA or percentage is optional and appears only when its remaining-work measure matches the rate; scanning, hashing, unknown service reuse, and commit waits do not receive invented estimates.

Expose retry attempt, reason category, next retry time, and an immediate Stop action. Retain current bounded request eligibility. Authentication failures, invalid source state, parent conflicts, and ambiguous commits require attention rather than automatic job replay. Cancellation during retry sleep must stop promptly. Persistent recovery guidance should use typed errors where available, with the current text classifier as a fallback.

## Receipt and persistence contract

Add `TransferAttempt`, `TransferReceipt`, and `TransferHistoryArchive` alongside the existing queue archive. Persist an attempt before remote mutation and checkpoint confirmed commit evidence as it arrives. Finalization is idempotent by attempt ID. On relaunch, unfinished attempts become interrupted; a crash between a remote response and local persistence must leave uncertainty visible.

Each receipt includes job/attempt IDs, destination, reviewed plan identity, start/end times, terminal outcome, known planned and observed counts, confirmed commits/URLs, retry summary, and a redacted error category/message. Preserve unknown values explicitly. Confirmed commits describe completed work even when the overall attempt failed or stopped.

Receipts remain available when a queue item is removed; a separate Clear history action controls their retention. Use bounded summary records, paginated display, and a documented retention default finalized in milestone 0. Avoid duplicating complete per-file plans in every receipt. Keep tokens, signed URLs, raw HTTP bodies, dataset contents, and security bookmarks out of receipts. A copied receipt omits absolute local paths by default.

Keep recovery checkpoints separate from history. Preserve existing job IDs, bookmarks, filters, and checkpoint validity during migration. Legacy jobs retain their recorded outcome and timestamps, while unrecorded byte counts and commit IDs remain unknown. Update privacy documentation to describe retained summaries and history removal.

## Pairings and Mac entry

Extend pairing persistence with optional/defaulted pinning and ordering metadata. Search by name, source label, repository, and destination. Rename preserves pairing identity and route. The active indication clears when the prepared source, repository, destination, or filters diverge; use the source identity/bookmark rather than relying only on its display path.

Use one staging entry point for the folder picker, in-window drop, and Dock open events. Preserve unsaved dataset-card and prepared-workspace protections. A folder opens the workspace without starting a transfer. Multiple folders receive a clear selection flow; unsupported files receive an explanation. Validate security-scoped access and bookmark restoration in the signed sandboxed app, including a cold launch through the Dock. A Finder Quick Action is a follow-up option after this entry path is verified.

## Implementation milestones

The effort below is a planning estimate for one engineer: 14–22 engineering days, roughly three to five working weeks, before any external review wait. Milestone 0 should refine it.

| Milestone | Deliverable and acceptance | Estimate |
| --- | --- | --- |
| 0. Contracts and feasibility | Verify content identity and parent-guard HTTP fixtures, revision pagination, unknown/new-repository cases, event metrics, archive migration, and receipt retention. Settle typed result shapes and an integration fixture matrix. | 1–2 days |
| 1. Typed lifecycle and receipts | Replace native event-to-JSON round trips with an ordered reducer; persist attempt/commit/terminal summaries; support old archives; show and copy receipts after relaunch. Existing stop/queue semantics continue to pass. | 2–3 days |
| 2. Review and execute a plan | Implement disk-backed planning, supported equality checks, review UI, stale-plan handling, guarded batch commits, and all-identical completion. Execution uses the same approved action set. | 5–8 days |
| 3. Progress and recovery UI | Expose phases, measured upload-body activity, retry waits, typed guidance, and responsive Stop. Prove correct accounting for retries, reuse, inline files, and interrupted commits. | 2–3 days |
| 4. Pairings and Dock | Ship rename/search/pinning/active state and common folder staging. Verify old pairings and signed sandboxed Dock access. | 2–3 days |
| 5. Release verification | Run regression, bounded native integration, accessibility/layout, archive migration, supported-OS/architecture, and exact package checks; update privacy/release notes. | 2–3 days |

Milestone 0 comes first. Milestone 1 supplies the event/history foundation for milestones 2 and 3. Pairing polish can proceed independently once persistence defaults are settled; it must not expand into project/sync management. If scope needs trimming, preserve review correctness, receipt integrity, and cancellation before convenience features or ETA.

## Validation and release gates

- Use focused core tests for full-plan completeness, hashing/identity mismatches, missing remote metadata, Unicode paths, filters, repository rules, changed source, stale remote revision, guarded commit conflicts, all-identical plans, and empty/new repositories.
- Exercise a many-file synthetic tree beyond the preview limit and page the plan from disk. Cancel during enumeration, hashing, remote pagination, retry wait, upload, and commit settlement; verify temporary-file cleanup and bounded memory.
- Drive typed event tests with delayed, duplicated, and stale-attempt callbacks. Verify retry-byte accounting, zero-body reuse, inline-body accounting, terminal ordering, and one receipt per attempt.
- Test process restart after attempt creation, partial commit, terminal persistence, and archive migration. Preserve confirmed partial results and unknown outcomes; do not infer success from a sent request.
- Run `Scripts/check.sh --build` after implementation, plus focused native smoke extensions. Historical Python tests remain regression evidence rather than verification of new native features. Live writes require specifically authorized disposable fixtures and verified cleanup; the retained App Review repository is not a disposable test target.
- Verify the signed sandboxed UI for review, queue staleness, Stop/Resume, history, active pairings, and cold/warm Dock entry. Check keyboard navigation, accessibility labels, light/dark appearance, long names, and large counts.
- Verify macOS 15 launch and actual Intel execution separately from a valid universal binary. Run the exact Release package audit and inspect the app expanded from its installer. Keep platform execution gaps visible until tested.

## First implementation slice

Start with milestone 0's source/remote identity and commit-precondition fixtures, then milestone 1's typed attempt and result path. The first reviewable code change should preserve current upload behavior while proving ordered native events, accurate terminal results, and receipt migration. Build upload planning on that foundation in the next slice.

## Implementation status

October 27, 2026: the first development slice adds typed, serialized native event reduction and durable attempt receipts. Commit acknowledgements are recorded before local recovery-checkpoint writes; unfinished attempts recover as interrupted. Native uploads no longer round-trip through legacy JSON lines to update the UI. The activity shelf exposes receipt history, copying, links to confirmed commits, and history removal independently of queue removal.

Receipt retention is the latest 200 terminal attempts plus the active attempt; each receipt retains its last 20 commit references and the full acknowledged commit/file counts. Legacy queue history is imported once with unrecorded measurements left unknown. Receipt persistence errors pause further work and remain visible.

The upload-review slice adds a complete SQLite inventory, shared bounded source hashing, Git SHA-1/SHA-256 blob and LFS content comparison, action counts, filtered page reads, and explicit acknowledgement of unknown comparisons. The review sheet binds approval to a particular source, account, destination, filters, visibility, and revision. No content negotiation or upload occurs while building a review.

New and re-reviewed jobs execute through `ReviewedUploader`: it checks the full included source set, revalidates the account and remote state, skips verified identical files, and guards each commit against the expected parent. Acknowledged batches advance both the expected revision and their completed-path checkpoints atomically in the plan. An unacknowledged or foreign commit requires a fresh review. All-identical completion records a verified revision without claiming a new commit; server-ignored files are counted separately. Older jobs without a plan first open a review.

A repository with no confirmed revision produces an explanatory blocked review. Initial-commit execution remains unavailable until the service's corresponding precondition can be verified; there is no unguarded fallback. Already initialized repositories with an empty tree are valid review targets. Fresh reviews show current visibility and require the approved job to match it.

Milestones 0–2 now have core implementation and synthetic contract/recovery coverage, with the no-revision limitation above. Signed sandboxed interactions, live reviewed-upload smoke tests, older-platform execution, and installer audits remain release gates. See the [foundation record](verification/1.1-foundation.md) and [upload-review record](verification/1.1-upload-review.md).

The transfer-activity slice exposes upload/review phases and request retry reasons, attempt limits, and countdowns. Measured file/commit-body throughput uses a bounded monotonic sample window and clears during waits, idle periods, and terminal states. Observed request-body totals include explicit retry sends and encoded inline commits; logical file progress remains separate. Receipts retain raw body totals, retry summaries, and the last observed phase/time, while older measurements remain unknown. Retry waits remain cancellable and do not replay ambiguous commits. See the [transfer-activity verification record](verification/1.1-transfer-activity.md).

The pairing/entry slice adds backward-compatible pin/order metadata, route search, rename, pinning, manual ordering, and an active indication bound to the resolved folder identity and route/filters. Picker, window drop, and native open events now share folder staging and replacement protection. Multiple folders open a selection sheet; unsupported files/packages are explained, and open events never start uploads. Cold-launch events retain folder scopes until the workspace attaches. See the [pairings and entry record](verification/1.1-pairings-entry.md).

Milestones 0–4 now have development implementation with the limitations and validation gaps documented above. Next: signed sandboxed workflow and Dock verification, live disposable-fixture checks when specifically authorized, accessibility interaction, supported-OS/architecture execution, and exact Release package audits. Aether Kit integration remains independent.

# Face Hugger roadmap

Agreed direction as of October 27, 2026. Version 1.1 is in development; version 2.0 describes the product direction, with its delivery scope to be refined as the transfer workflow matures. See the [1.1 implementation plan](plan-1.1.md) for sequencing, acceptance criteria, and implementation status.

Face Hugger helps people prepare, inspect, document, and publish models and datasets from a native Mac workspace. The Transfer Bench remains the center of the experience: local files, the remote destination, and the consequences of the next action stay visible together.

## Version 1.1

The next minor release makes every upload understandable and recoverable. A person should be able to review what will happen, see what the app is doing, and find a dependable record afterward.

| Area | Intended behavior |
| --- | --- |
| Upload review | Show additions, replacements, verified identical files, exclusions, conflicts, and unresolved comparisons across the full selected file set. Explain estimated content size and what remains unknown about actual transfer size. |
| Progress and recovery | Show scanning, comparison, hashing, uploading, committing, and retry waits. Report measured transfer activity and actionable failures. Preserve bounded request retries and explicit stop/resume. |
| Transfer receipts | Retain outcomes, observed counts, timestamps, destination, and confirmed commit references across relaunches. Offer a copyable receipt and a route back to the destination. |
| Saved pairings | Add rename, search, pinning, predictable ordering, and a visible active pairing. Keep folder access and destination details easy to inspect. |
| Mac entry points | Extend existing in-window folder dropping with Dock entry and a quick route to a saved destination. Review remains explicit before upload. |

The existing in-window folder drop, queue persistence, file-level recovery checkpoints, bounded HTTP retries, and dataset-card editor are foundations for this work. The new release improves and connects them; the [implementation plan](plan-1.1.md#existing-foundations) distinguishes current behavior from new work.

Version 1.1 retains the current macOS 15 deployment target and universal packaging goal. It can proceed independently of Aether Kit's SDK work. Scheduling, background transfers after quitting, downloads, automatic synchronization, parallel upload workers, and a replacement inference backend are outside this release's scope.

## Version 2.0

The next major release develops saved pairings into projects that connect a local folder with a Hub repository. A project remembers its destination, revision, filters, documentation, and last verified transfer.

| Capability | Intended behavior |
| --- | --- |
| Downloads and snapshots | Retrieve selected files or a complete pinned revision into a chosen local folder. |
| Explicit reconciliation | Compare local and remote state in either direction, review a change plan, resolve conflicts, and apply the selected actions. |
| Revision workflows | Work with branches, tags, and identifiable releases so a publication has a reproducible identity. |
| Repeatable publishing | Save release recipes containing file selection, destination, documentation, and checks to perform before publishing. |
| Artifact inspection | Preview dataset samples and schemas, inspect model metadata, and surface missing documentation before publication. |

The broader product direction is an ML release workbench: prepare, inspect, test, document, and publish from one workspace. Projects and reliable transfers form its foundation. The exact inspection formats, testing integrations, and automation belong in later scoped plans.

## Aether Kit integration

Aether Kit can support these features as its consumer APIs and platform support mature:

- Editable dataset and model cards with reusable templates and suggested revisions.
- Release descriptions grounded in the reviewed changes and confirmed transfer results.
- Small saved prompt suites for models supported by Kit, with results attached to a release.
- Optional documentation suggestions alongside deterministic checks for missing files and metadata.

Adoption should use Kit's text-level APIs, explicit readiness states, complete model bundles, and a verified sandboxed loading path. The current FoundationModels drafting path and deterministic template remain available until an independently scoped migration is ready. Model execution support must be described for the exact supported assets and devices.

## Product rules

- Preparing a folder, selecting a pairing, reviewing changes, or generating documentation does not publish anything. Upload and reconciliation actions remain explicit.
- Content equality requires evidence. Missing metadata and incomplete comparisons remain visible as unknown.
- A successful receipt reflects acknowledged remote state. Interruptions and uncertain commits remain distinguishable from success.
- Large file sets use bounded memory and disk-backed indexes. Verification can use bounded synthetic data and many-file fixtures.
- Preserve the paired file surfaces, compact toolbar pairings, activity shelf, native controls, and existing artwork.
- AI assists with documentation and supported model checks. File selection, byte counts, hashes, transfer outcomes, and publication decisions come from deterministic state and the person using the app.

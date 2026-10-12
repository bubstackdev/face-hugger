# Face Hugger handoff — October 2, 2026

## Current outcome — build 6 attached

Build 6 (`62d74e22-0d89-4f50-900c-a6f1a6fbf043`) is attached to the draft as of October 2, 2026. It is build 5's code (build 4's native backend plus the dataset-card editor) with the new original icon and mascot: a coral creature hugging a manila folder with an upload arrow, on the slate-blue tile. Unsigned executables match build 5 byte for byte. Validation: 0 errors, 0 warnings, 0 blockers. Its expanded installer passed the native audit; FoundationModels is weak-linked for macOS 15. See [native evidence](native-backend-release.md#build-6--original-icon-attached-to-the-app-store-draft). The review notes no longer name a build number. Four genuine build-6 screenshots, including an on-device dataset-card draft, replaced the build-3 set; see [capture provenance](../AppStore/screenshots/README.md). Capture used shell `screencapture` plus System Events accessibility scripting; the app must be frontmost, so keystrokes typed on the Mac during capture land in it. Before submitting: confirm the review details' password matches the app's working token, run on macOS 15 and Intel or Rosetta, and do the browser-only checks. Nothing submitted or released.

## Native build 4

The native replacement is implemented, signed, and audited. Networking uses URLSession, hashing uses CryptoKit, and the package contains no Python/OpenSSL/Xet runtime. 66 Swift tests and the live 16 MiB cancellation/fresh-process-resume/download-verification flow passed, with disposable test repositories cleaned. The signed sandboxed UI also restored its saved bookmark and uploaded the approved four-file fixture. See [native backend evidence](native-backend-release.md) and [current App Store state](../AppStore/README.md). Build 4 (`f701748b-9e6a-45e1-a4cf-771e656f7dad`) is processed VALID and attached to the existing draft. Apple reports `usesNonExemptEncryption=false`; latest ASC validation has 0 errors/warnings/blockers. It contains the approved icon. No App Review submission or public release.

The sections below record the historical build-3 implementation; they do not describe the current native package.

## Historical build 3 outcome

Native macOS Transfer Bench design is preserved. The owner requested a more cartoon-like creature and nonwhite icon background; the revised smooth emoji artwork is in Resources/Artwork/face-hugger-icon-v2.png, with mechanical icon-size packaging in Scripts/Art/build_assets.swift. Build 3 packages this icon and the supplemental LibYAML notice and is attached to the draft. Store variant **1.0 (3)** now has a self-contained universal upload runtime, App Sandbox, persistent folder bookmarks, nested signatures, and a signed installer. Package `dist/store/FaceHugger-1.0-3.pkg` uploaded and attached to the ASC draft. Nothing submitted for App Review or released; release remains manual.

App `6817866865`; bundle `dev.zakkeown.FaceHugger`; version `6302c414-5900-40dd-bb0d-2b886d65496b`; build `d2ccd249-8a5f-4e4b-a36d-c0386cdc296b`; SKU `FACEHUGGER`. Full listing state and remaining gates: [AppStore/README.md](../AppStore/README.md).

## Implemented and verified

- Large-directory responses stream bounded item events with strict JSONL framing and terminal-count checks; oversized or partial results fail explicitly.
- Folder security bookmarks persist in jobs/pairings; independent leases retain access until scans/helpers end. Legacy path-only records remain decodable.
- Python 3.12.14 and 15 runtime packages are pinned with hashes. Direct setup uses isolated support/cache locations. Store downloads no runtime and uses bundled architecture-specific Python, container caches, and explicitly entered Keychain tokens.
- Store package signatures/profile and both native slices verified. Relocated arm64 runtime imports and CLI checks passed. Intel is structurally verified, not executed (no Rosetta).
- 32 Swift and 56 Python tests passed. Direct and Store builds passed.
- Development-signed sandbox probe proved folder read/write, bookmark restoration in a new process, denied access before restoration, and inherited helper permissions. Real sandboxed HF upload downloaded back byte-identically; disposable repository/files cleaned. Actual Store UI scanned a harmless fixture and displayed included-tools settings. See [sandbox-verification.md](sandbox-verification.md).
- Python native notices, wheel notices, and source notices for all 237 HF Xet SBOM identities retained. See [notice audit](third-party-notices.md) for limitations and provenance.

## Owner-approved listing and review access

Free, all current/future territories, Developer Tools, 13+ minimum, approved third-party content-rights declaration. Privacy policy published with public contact zak.k.ai@outlook.com; moved on October 12, 2026 to https://bubstack.dev/face-hugger/privacy.html with contact support@bubstack.dev (App Store Connect URLs updated to match; build 6 still links to the GitHub copy in-app, which redirects). App Privacy published: User ID and Other User Content, linked for App Functionality, no tracking. Private review contact and restricted-token credentials saved and browser reload-verified.

Retain private dataset `zakkeown/face-hugger-app-review-89503494` and token **Face Hugger App Review** through review; revoke/delete afterward. Token resides in ASC private review credentials, not files/Git. HF requires selected-repository read/write plus gated-request view and allows public reads; no global private/org scope. Do not print ASC review-password fields or screenshot them. Private contact JSON is ignored under `.build`.

## Signing and tools

ASC CLI `/opt/homebrew/bin/asc` (5.9.0), profile `SpaceCase`, `ASC_TELEMETRY_DISABLED=1`. The CLI's default profile is a different account, so always pass `--profile SpaceCase`. API auth is in Keychain; CLI web MFA failed historically, while Safari is signed in. Do not recreate the app or retry web MFA for API tasks.

Team `3FMAPDQDGP`. Store application certificate `J96CN8H3CC`, identity `D9C38F064E9E179FDEA737994F4D32550439EEA7`; installer certificate `7HQ7WWX8TW`, identity `4CCB7F23C5F79F2F5AFE4C9D59FB7F9F6FBB2BB3`; profile `6TA8PNK7KK`, **Face Hugger Mac App Store**, UUID `a7216289-cdf0-41be-97ca-718aa5e31617`. Keys are in login Keychain; raw temporary keys/CSRs removed. See [store-build.md](store-build.md).

The original Developer ID-notarized direct beta `dist/beta/FaceHugger-0.1.0-beta.1-universal-notarized.dmg` predates these fixes. Rebuild/notarize a new artifact before distributing current direct-build code. Do not describe the old DMG as containing this work.

## Historical build-3 resume checklist

1. Inspect Git and latest ASC validation; preserve unrelated changes.
2. Screenshots are complete: four 2560 × 1600 assets uploaded and processed COMPLETE. The capture record is in AppStore/screenshots/README.md. Preserve untouched originals and checksums.
3. Resolve [export compliance](export-compliance.md), including the bundled TLS implementation and approved France availability. No exemption declaration was inferred.
4. Complete remaining dependency obligations and clean-machine/Intel/Store recovery verification. Do not claim multi-terabyte testing; owner lacks that disk capacity.
5. Rebuild with a new build number if package resources/code change, upload/attach, validate, then seek explicit submission approval. Preparation is authorized; submission/release has not been requested.

The user approved subagents and test repos with cleanup; the review repo is the explicit persistent exception. Preserve the approved paired-surface/slate-shelf design and friendly facehugger artwork.

## Screenshot and encryption follow-up

Owner approved the revised icon, continued screenshots/compliance work, and explicitly authorized macOS `screencapture` after the native Screenshot UI failed. Four real Store build 3 screenshots are uploaded and processed COMPLETE, and retained under `AppStore/screenshots/1.0-build3`, including an actual four-file upload using restricted review access. The review repository/token remain intentionally available through review.

Build 3 `usesNonExemptEncryption=true`. Declaration `deb48a27-898e-44dc-8da5-77c2cf681899`: third-party cryptography yes, proprietary no, France yes; state CREATED. CLI assignment reported success but readback contained no builds. Browser explicitly requires a French encryption declaration approval form and disables Save until one is supplied; its incomplete API-created row displays Upload Failed. Do not represent the drafts as approval.

Owner requested preparation of French filing materials, preserving France availability. `output/pdf/` contains a visually verified three-page worksheet, six-page technical attachment, and unchanged official dynamic XFA PDF. Editable sources live in `docs/encryption-filing-worksheet.md` and `docs/encryption-technical-description.md`. Identity/address/nationality, signature, operation/classification and required supporting evidence need owner completion. Nothing was sent to ANSSI.

## Current direction: Apple-native backend investigation

The owner opted to investigate Apple-native networking instead of continuing French paperwork. A standalone Swift URLSession/CryptoKit proof passed two real 16 MiB/two-part LFS upload, commit, download-hash and cleanup runs; final run verified completed-file deduplication. Production remains unchanged. See `Experiments/NativeTransport/README.md` for results, tradeoffs and replacement gates. Current Python embeds OpenSSL statically; a custom HTTP factory alone cannot remove it. Native LFS avoids Python/Xet but needs durable recovery/scheduling and sacrifices Xet chunk-level deduplication. Do not change build 3 compliance to exempt: only an audited future native package can support revised answers.

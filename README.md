<p align="center">
  <img src="Resources/Assets.xcassets/Hugger.imageset/hugger.png" width="160" alt="Face Hugger mascot">
</p>

# Face Hugger

A native Mac upload manager for Hugging Face. Give your big folders a home.

Face Hugger brings a local file preview, remote repository browser, and persistent upload queue into one SwiftUI workspace for macOS 15 and later. **Store build 1.0 (6) is built, signed, and attached to the App Store draft; release validation is still in progress.** Existing direct beta and Store build 3 artifacts use the older Python/Hugging Face CLI backend; their verification results do not establish native-build behavior.

## Workspace

- Prepare model or dataset folders with destination paths and include/exclude globs.
- Review remote path conflicts before uploading. Matching paths do not prove identical contents.
- Queue jobs, stop transfers, and choose when to retry interrupted work.
- Browse remote folders, create public or private repositories, and delete individual files after confirmation.
- Draft an editable dataset card from measured folder metadata, with optional on-device Apple Intelligence and an always-available template.
- Connect using a Hugging Face access token stored in macOS Keychain.
- Save folder–repository pairings, keep uploads running after closing the window, optionally prevent idle sleep, and receive completion notifications.

The native engine uses Apple URLSession and CryptoKit against Hugging Face HTTP APIs. It needs no Python installation or bundled workers. Live multipart transfer, cancellation, fresh-process resume, and downloaded hashes have passed verification. Recovery reuses confirmed files; unfinished multipart transfers restart. It does not implement Xet chunk-level deduplication or promise multi-terabyte performance.

## Roadmap

Version 1.1 focuses on upload review, clearer progress and recovery, durable transfer receipts, saved-pairing improvements, and Dock folder entry. Version 2.0 develops local–Hub projects and repeatable ML publishing. See the [roadmap](docs/roadmap.md) and [1.1 implementation plan](docs/plan-1.1.md).

The 1.1 development build adds a complete upload-review sheet backed by an on-disk plan. It compares supported content identities, requires approval for unresolved comparisons, and executes reviewed actions with parent-commit guards. Typed native events support durable receipts, phase indicators, measured upload-body speed, and cancellable retry countdowns. Logical file progress and observed request-body totals are reported separately. See the [transfer-activity record](docs/verification/1.1-transfer-activity.md), [upload-review record](docs/verification/1.1-upload-review.md), and earlier [foundation record](docs/verification/1.1-foundation.md).

It also adds searchable saved pairings with rename, pinning, ordering, and active-route tracking. Opening folders through the Dock uses the same guarded staging as the folder picker and in-window drop. Multiple folders receive a chooser; opening a folder never starts an upload. See the [pairings and entry verification record](docs/verification/1.1-pairings-entry.md) for implemented behavior and remaining signed-app checks.

## Build and run

You need macOS 15+, Xcode with Swift 6 support, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project FaceHugger.xcodeproj -scheme FaceHugger \
  -configuration Debug -derivedDataPath .build/xcode build CODE_SIGN_IDENTITY=-
open ".build/xcode/Build/Products/Debug/Face Hugger.app"
```

Connect with a token that can write to the chosen repository. Select a local folder and destination, review filters, then start the upload. Matching remote paths may be replaced; other files remain. Source folders stay live rather than being snapshotted. The native engine checks for changes and requires a new job when a saved upload’s source changes. Stopping does not undo remote commits. Closing the window leaves the app running; quitting stops an active transfer.

For dataset repositories, choose **Dataset card…** beside the remote folder controls. Add purpose, source, license, and limitations; use the template or **Draft on this Mac**. The model rewrites only your purpose into an overview; measured facts and declarations stay deterministic. Existing local README files open for editing and side-by-side comparison. Save through the native dialog, then include the card in a new upload to the repository root. Nothing is published automatically. On-device generation needs macOS 26+, an Apple Intelligence-capable Mac with its model ready, and a build made with Xcode 26+; the template works on macOS 15 and Intel. This feature ships in Store builds 5 and 6; build 4 does not include it. The development build passed 71 Swift tests plus signed-app checks for on-device drafting, README comparison, local save, and unsaved-note protection; an actual model cancellation smoke test also passed. FoundationModels is weak-linked, so builds still launch on macOS 15.

[Privacy policy](https://bubstack.dev/face-hugger/privacy.html) · [Support](https://bubstack.dev/face-hugger/) ([support@bubstack.dev](mailto:support@bubstack.dev)) · [Native release gate](docs/native-backend-release.md)

## Limits and verification

Uploads require the app to remain running and the Mac awake. There is no scheduled upload service. Repository management is limited to models and datasets; Spaces, branches, moves, remote card fetching, and whole-repository deletion are outside scope. Logs are bounded and session-only; queue and pairing metadata persist locally.

`Scripts/check.sh` is the repository check entry point. Some Python bridge tests and old live-test scripts remain as historical regression evidence; they are not native-engine integration tests. The production native live test is in `Scripts/NativeSmoke`; see the native release gate for its results. Tests that mutate remote repositories must use explicitly authorized disposable fixtures and verify cleanup.

The Store build uses [project-store.yml](project-store.yml) and [Store packaging](docs/store-build.md). Packaging performs a native-only binary/dependency audit before signing the installer. The older Developer ID beta packaging flow is documented in [releasing.md](docs/releasing.md); runtime setup instructions there describe the historical beta until that flow is revalidated.

Native build 6 has passed its package audit, is processed and attached to the App Store draft, and has an Apple-verified OS-only encryption flag. It is build 5's code with the new original icon and mascot. Builds 4 and 5 remain uploaded but are no longer attached. The old build-3 third-party TLS declaration remains historical. No App Review submission or release has occurred.

Face Hugger is an independent project, not an official Hugging Face application.

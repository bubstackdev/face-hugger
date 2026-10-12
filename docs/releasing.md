# Building a developer beta

`Scripts/package-beta.sh` builds a Release app and a drag-to-Applications disk image. It does not publish a release or upload an artifact unless notarization is explicitly enabled. The minimum OS is macOS 27, on Apple silicon. The app's first-run runtime setup needs internet access; the per-user upload runtime is not bundled in the DMG.

## Local package

On a Mac with Xcode and XcodeGen installed:

```sh
Scripts/check.sh
Scripts/package-beta.sh
```

The build is `arm64` only, because macOS 27 does not run on Intel Macs. It fails if the arm64 slice is missing.

Builds use an independently generated project and DerivedData inside `.build/beta/`, so packaging does not replace the Debug project's build products. Diagnostics are in `.build/beta/build.log`. The script reads the version and build number from the built app, using the values configured in `project.yml`.

Outputs are written to `dist/beta/` only after validation:

- `FaceHugger-<version>-beta.<build>-<architecture>-<signing>.dmg`
- A matching `.dmg.sha256` file.
- A matching `-build-info.txt` with source commit, working-tree state, toolchain, and architecture/signing status.

The DMG contains `Face Hugger.app`, an `Applications` link, and a short Read Me. Packaging verifies image integrity, mounts it read-only, checks the contained app's signature and architectures, and checks the Applications link. An interrupted script cleans up only its own `mktemp` staging directory. Rerunning replaces completed artifacts with the same version/architecture/signing filename.

The workflow is repeatable, but builds are not promised to be byte-for-byte reproducible: signatures, notarization tickets, and build/filesystem timestamps may differ. A checksum identifies the specific delivered DMG.

## Signing and notarization

Without configuration, the app is ad-hoc signed and the filename says `ad-hoc`. This is useful for local developer evaluation. **It is not a Developer ID-signed, notarized public beta; Gatekeeper may reject it on another Mac.** Dragging an app into Applications does not change its trust status. Do not present an ad-hoc artifact as a frictionless public installer.

To make a distributable beta, first install a valid Developer ID Application certificate and its private key in the local Keychain. Configure an existing `notarytool` Keychain credential profile locally; never put passwords, API private keys, or exported signing keys into this repository or chat.

Then run with the identity and profile names:

```sh
FACEHUGGER_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
FACEHUGGER_NOTARY_PROFILE='your-existing-notary-profile' \
FACEHUGGER_TEAM_ID='TEAMID' \
Scripts/package-beta.sh
```

`FACEHUGGER_TEAM_ID` is optional when the signing identity is sufficient. A signing identity without a notary profile produces a `signed-unnotarized` artifact. A notary profile with ad-hoc signing is rejected. Signing or notarization errors stop packaging; there is no fallback to a less trusted output.

An existing authenticated `asc` profile can submit through Apple's Notary API instead of `notarytool`:

```sh
FACEHUGGER_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
FACEHUGGER_ASC_PATH='/absolute/path/to/asc' \
FACEHUGGER_ASC_PROFILE='your-existing-asc-profile' \
Scripts/package-beta.sh
```

Supply both ASC variables. The script disables ASC telemetry, uses the named profile without extracting credentials, waits for the final JSON status, and requires `Accepted`. A configured `FACEHUGGER_NOTARY_PROFILE` takes precedence over ASC variables; a failed submission never triggers a second authentication method. Stapling and Gatekeeper checks still use Apple's local tools.

With both configured, the script signs with the hardened runtime and a secure timestamp, submits a ZIP of the app, requires an Accepted result, staples and validates the app ticket, and runs a Gatekeeper execution assessment. It then creates and signs the DMG, submits it separately, requires acceptance, staples and validates its ticket, and assesses the DMG. The SHA256 is generated after stapling. Submission status reports are kept in `.build/beta/notarization-app.json` and `notarization-dmg.json`; credentials remain in the Keychain.

No notarization occurs in the default local build. Notarization sends the app and disk image to Apple's service; setting either profile method enables that step. A notary timeout stops the script even though Apple's server may continue processing that submission.

## Before sharing

Use a clean, identified source revision, run the project checks, then build the intended signed/notarized artifact. Validate first launch and upload-tool setup on a Mac without an existing Face Hugger runtime. Test the architectures you intend to claim as runtime-verified: including both executable slices is not evidence that both ran successfully.

Verify a delivered DMG against its adjacent checksum with `shasum -a 256 -c <file>.dmg.sha256` from the output directory. Preserve the checksum and build-info file with the artifact. Publishing to GitHub or another destination remains a separate, explicit step.

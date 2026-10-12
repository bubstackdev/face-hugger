#!/bin/bash
# Build a local developer beta. Publishing is deliberately a separate operation.
set -euo pipefail

case "${1:-}" in
  "") ;;
  --help|-h)
    cat <<'HELP'
Usage: Scripts/package-beta.sh

Environment:
  FACEHUGGER_SIGN_IDENTITY  Code-signing identity; defaults to '-' (ad-hoc).
  FACEHUGGER_NOTARY_PROFILE Existing notarytool Keychain profile (optional).
  FACEHUGGER_ASC_PATH       asc executable for Notary API submission (optional).
  FACEHUGGER_ASC_PROFILE    Existing asc auth profile; used with ASC_PATH.
  FACEHUGGER_TEAM_ID        Developer team ID, if required by the identity.

Output: dist/beta/*.dmg, matching .sha256 and build-info.txt.
Builds use .build/beta, separately from the development app. No publishing.
HELP
    exit 0 ;;
  *) echo 'Usage: Scripts/package-beta.sh [--help]' >&2; exit 2 ;;
esac

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
beta_work="$repo_root/.build/beta"
beta_output="$repo_root/dist/beta"
sign_identity=${FACEHUGGER_SIGN_IDENTITY:--}
notary_profile=${FACEHUGGER_NOTARY_PROFILE:-}
asc_path=${FACEHUGGER_ASC_PATH:-}
asc_profile=${FACEHUGGER_ASC_PROFILE:-}
notary_method=none
if [[ -n "$notary_profile" ]]; then
  notary_method=notarytool
elif [[ -n "$asc_path" || -n "$asc_profile" ]]; then
  if [[ -z "$asc_path" || -z "$asc_profile" || ! -x "$asc_path" ]]; then
    echo 'ASC notarization requires an executable FACEHUGGER_ASC_PATH and FACEHUGGER_ASC_PROFILE.' >&2
    exit 2
  fi
  notary_method=asc
fi
# macOS 27 runs only on Apple silicon.
architectures=arm64
arch_label=arm64
if [[ "$notary_method" != none && "$sign_identity" == '-' ]]; then
  echo 'Notarization requires a Developer ID Application signing identity.' >&2
  exit 2
fi
for required in xcodegen xcodebuild codesign hdiutil ditto shasum; do
  command -v "$required" >/dev/null || { echo "Missing required tool: $required" >&2; exit 1; }
done
mkdir -p "$beta_work/project" "$beta_output"
package_tmp=$(mktemp -d "${TMPDIR:-/private/tmp}/face-hugger-beta.XXXXXX")
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then hdiutil detach "$package_tmp/mount" -quiet || true; fi
  # Only remove the private directory created by mktemp above.
  rm -rf -- "$package_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Generate a separate project so a parallel Debug build's project is untouched.
xcodegen generate --spec "$repo_root/project.yml" --project-root "$repo_root" --project "$beta_work/project" --quiet
# XcodeGen resolves this top-level file resource beside the generated project.
# Only the narrow native matcher notice is copied; no legacy runtime resources.
mkdir -p "$beta_work/project/Resources"
cp "$repo_root/Resources/PythonFnmatchLicense.txt" "$beta_work/project/Resources/PythonFnmatchLicense.txt"
build_args=(
  -project "$beta_work/project/FaceHugger.xcodeproj"
  -scheme FaceHugger -configuration Release
  -derivedDataPath "$beta_work/DerivedData"
  -destination 'generic/platform=macOS'
  "ARCHS=$architectures" ONLY_ACTIVE_ARCH=NO
  "CODE_SIGN_IDENTITY=$sign_identity" CODE_SIGN_STYLE=Manual
  ENABLE_HARDENED_RUNTIME=YES
)
if [[ -n "${FACEHUGGER_TEAM_ID:-}" ]]; then build_args+=("DEVELOPMENT_TEAM=$FACEHUGGER_TEAM_ID"); fi
printf 'Building Release (%s)…\n' "$architectures"
if ! xcodebuild "${build_args[@]}" clean build > "$beta_work/build.log" 2>&1; then
  echo "Build failed. Inspect $beta_work/build.log" >&2
  tail -n 35 "$beta_work/build.log" >&2
  exit 1
fi
built_app="$beta_work/DerivedData/Build/Products/Release/Face Hugger.app"
[[ -d "$built_app" ]] || { echo 'Build did not produce Face Hugger.app.' >&2; exit 1; }
mkdir -p "$package_tmp/staging"
app="$package_tmp/staging/Face Hugger.app"
ditto "$built_app" "$app"
# Verify each requested architecture. Do not silently produce a narrower beta.
for architecture in $architectures; do
  xcrun lipo -verify_arch "$architecture" "$app/Contents/MacOS/Face Hugger"
done
if [[ "$sign_identity" == '-' ]]; then
  signing_label=ad-hoc
else
  signing_label=signed-unnotarized
  # Xcode signs nested code; this final signature adds a secure timestamp.
  codesign --force --sign "$sign_identity" --options runtime --timestamp "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

notarize() {
  local target=$1
  local report=$2
  local status=''
  # Credentials stay in the Keychain. Never accept or print a password/API key.
  if [[ "$notary_method" == notarytool ]]; then
    xcrun notarytool submit "$target" --keychain-profile "$notary_profile" \
      --wait --timeout 30m --output-format json > "$report"
    status=$(/usr/bin/plutil -extract status raw -o - "$report")
  else
    ASC_TELEMETRY_DISABLED=1 "$asc_path" --profile "$asc_profile" notarization submit \
      --file "$target" --wait --timeout 30m --output json > "$report"
    # asc returns the Notary API JSON:API resource. Accept flattened responses
    # from versions that expose the same final status at the top level, too.
    for status_key in data.attributes.status attributes.status status; do
      if status=$(/usr/bin/plutil -extract "$status_key" raw -o - "$report" 2>/dev/null); then break; fi
    done
  fi
  if [[ "$status" != Accepted ]]; then
    echo "Notarization was not accepted. Inspect $report" >&2
    exit 1
  fi
}
if [[ "$notary_method" != none ]]; then
  echo 'Notarizing the signed app…'
  ditto -c -k --keepParent "$app" "$package_tmp/FaceHugger-notary.zip"
  notarize "$package_tmp/FaceHugger-notary.zip" "$beta_work/notarization-app.json"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
  signing_label=notarized
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
case "$version-$build_number" in
  *[!A-Za-z0-9._-]*) echo 'Unsafe version/build value in Info.plist.' >&2; exit 1 ;;
esac
artifact="FaceHugger-${version}-beta.${build_number}-${arch_label}-${signing_label}"
ln -s /Applications "$package_tmp/staging/Applications"
cat > "$package_tmp/staging/Read Me.txt" <<README
Face Hugger ${version} (build ${build_number}) — developer beta

Drag Face Hugger.app to Applications.
Requires macOS 27 or later on Apple silicon. First-run upload-tool setup requires internet access.
Runtime tools are installed per user; they are not bundled inside this disk image.

Package signing: ${signing_label}
An ad-hoc or unnotarized build is for developer evaluation and may be rejected by
Gatekeeper on another Mac. It is not a signed, notarized public release.

No upload starts automatically. Connect your Hugging Face account, prepare a
folder, review the destination, then explicitly upload.
README
printf 'Creating %s.dmg…\n' "$artifact"
hdiutil create -volname 'Face Hugger' -srcfolder "$package_tmp/staging" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 "$package_tmp/$artifact.dmg" -quiet
if [[ "$sign_identity" != '-' ]]; then
  codesign --force --sign "$sign_identity" --timestamp "$package_tmp/$artifact.dmg"
fi
if [[ "$notary_method" != none ]]; then
  echo 'Notarizing the disk image…'
  notarize "$package_tmp/$artifact.dmg" "$beta_work/notarization-dmg.json"
  xcrun stapler staple "$package_tmp/$artifact.dmg"
  xcrun stapler validate "$package_tmp/$artifact.dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$package_tmp/$artifact.dmg"
fi

# Inspect the actual read-only image, not just its source folder.
hdiutil verify "$package_tmp/$artifact.dmg" -quiet
mkdir "$package_tmp/mount"
hdiutil attach "$package_tmp/$artifact.dmg" -readonly -nobrowse -mountpoint "$package_tmp/mount" -quiet
mounted=1
[[ -d "$package_tmp/mount/Face Hugger.app" ]]
[[ "$(readlink "$package_tmp/mount/Applications")" == /Applications ]]
[[ -f "$package_tmp/mount/Read Me.txt" ]]
codesign --verify --deep --strict --verbose=2 "$package_tmp/mount/Face Hugger.app"
for architecture in $architectures; do
  xcrun lipo -verify_arch "$architecture" "$package_tmp/mount/Face Hugger.app/Contents/MacOS/Face Hugger"
done
hdiutil detach "$package_tmp/mount" -quiet
mounted=0

{
  printf 'Face Hugger %s (build %s)\n' "$version" "$build_number"
  printf 'Architectures: %s\nSigning: %s\n' "$architectures" "$signing_label"
  printf 'Notarization client: %s\n' "$notary_method"
  printf 'Source commit: '; git rev-parse HEAD 2>/dev/null || printf 'unknown\n'
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then printf 'Source working tree: contains changes\n'; else printf 'Source working tree: clean\n'; fi
  printf 'Built at: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
  xcodebuild -version
  printf '\nVerified disk-image integrity, mounted app signature, requested architectures, and Applications link.\n'
} > "$package_tmp/$artifact-build-info.txt"
# Move only completed/verified artifacts into dist. Existing same-version outputs are replaced.
mv "$package_tmp/$artifact.dmg" "$beta_output/$artifact.dmg"
mv "$package_tmp/$artifact-build-info.txt" "$beta_output/$artifact-build-info.txt"
(cd "$beta_output" && shasum -a 256 "$artifact.dmg" > "$artifact.dmg.sha256")
printf 'Ready: %s/%s.dmg\nChecksum: %s/%s.dmg.sha256\n' "$beta_output" "$artifact" "$beta_output" "$artifact"
if [[ "$signing_label" != notarized ]]; then
  echo 'Developer beta only: this package is not notarized for public distribution.'
fi

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# This gate inspects the exact bundle that will enter productbuild. It does not
# infer export-compliance eligibility or replace source/dependency review.
audit_native_app() {
    local bundle="$1" report_dir="$2" executable entry kind dependency architecture
    executable="$bundle/Contents/MacOS/Face Hugger"
    test -f "$executable" || { echo 'Native app executable missing.' >&2; return 1; }
    mkdir -p "$report_dir"
    : > "$report_dir/macho-inventory.txt"
    while IFS= read -r -d '' entry; do
        case "$entry" in
            */UploadRuntime.bundle|*/UploadRuntime.bundle/*|*/site-packages/*|*/Python.framework/*|*/ThirdParty/*|*/bridge.py|*/requirements.txt|*/runtime-requirements.txt|*.py|*.pyc|*.pyo|*.so|*/python|*/python[0-9]*|*/uv|*/uvx)
                printf 'Unexpected legacy runtime resource: %s\n' "$entry" >&2; return 1 ;;
        esac
        if [[ -f "$entry" ]]; then
            kind=$(file -b "$entry")
            if [[ "$kind" == *Mach-O* ]]; then
                printf '%s: %s\n' "${entry#"$bundle"/}" "$kind" >> "$report_dir/macho-inventory.txt"
                [[ "$entry" == "$executable" ]] || { printf 'Unexpected embedded native binary: %s\n' "$entry" >&2; return 1; }
            fi
        fi
    done < <(find "$bundle" -print0)
    # macOS 27 runs only on Apple silicon, so the executable must be arm64 alone.
    [[ "$(lipo -archs "$executable")" == arm64 ]] || { echo 'Executable must contain only arm64.' >&2; return 1; }
    for architecture in arm64; do
        lipo "$executable" -verify_arch "$architecture"
        otool -arch "$architecture" -L "$executable" > "$report_dir/dependencies-$architecture.txt"
        while IFS= read -r dependency; do
            case "$dependency" in
                /System/Library/*|/usr/lib/*) ;;
                *) printf 'Non-system dependency (%s): %s\n' "$architecture" "$dependency" >&2; return 1 ;;
            esac
        done < <(awk '/^[[:space:]]/ {print $1}' "$report_dir/dependencies-$architecture.txt")
        nm -arch "$architecture" -u "$executable" > "$report_dir/undefined-symbols-$architecture.txt"
        if LC_ALL=C grep -E '_(OPENSSL_|SSL_|EVP_|CRYPTO_|Py[A-Z]|rustls_)' "$report_dir/undefined-symbols-$architecture.txt"; then
            echo 'Unexpected third-party runtime/crypto symbol; investigate before packaging.' >&2
            return 1
        fi
    done
    codesign --verify --strict --deep "$bundle"
    codesign -d --entitlements :- "$bundle" > "$report_dir/entitlements.plist" 2> "$report_dir/signature.txt"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$report_dir/entitlements.plist")" == true ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$report_dir/entitlements.plist")" == true ]]
    shasum -a 256 "$executable" > "$report_dir/executable.sha256"
    printf 'Native-only bundle audit passed: %s\n' "$bundle"
}

if [[ "${1:-}" == --audit-app ]]; then
    [[ $# == 2 ]] || { echo 'Usage: Scripts/package-store.sh --audit-app APP_PATH' >&2; exit 2; }
    audit_native_app "$2" .build/store-package/native-audit
    exit
fi

: "${FACEHUGGER_STORE_APP_IDENTITY:?Set a Mac App Store application signing identity}"
: "${FACEHUGGER_STORE_INSTALLER_IDENTITY:?Set a Mac App Store installer signing identity}"
: "${FACEHUGGER_STORE_PROFILE:?Set the installed Mac App Store provisioning profile name}"
: "${FACEHUGGER_TEAM_ID:?Set the Apple developer team ID}"

mkdir -p .build/store-package dist/store
xcodegen generate --spec project-store.yml
xcodebuild -project FaceHuggerStore.xcodeproj -scheme FaceHugger \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath .build/store-package/DerivedData \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    "CODE_SIGN_IDENTITY=$FACEHUGGER_STORE_APP_IDENTITY" \
    "PROVISIONING_PROFILE_SPECIFIER=$FACEHUGGER_STORE_PROFILE" \
    "DEVELOPMENT_TEAM=$FACEHUGGER_TEAM_ID" CODE_SIGN_STYLE=Manual \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    clean build > .build/store-package/build.log 2>&1 || {
        tail -n 40 .build/store-package/build.log >&2
        exit 1
    }
app='.build/store-package/DerivedData/Build/Products/Release/Face Hugger.app'
audit_native_app "$app" .build/store-package/native-audit
test -f "$app/Contents/embedded.provisionprofile"
lipo "$app/Contents/MacOS/Face Hugger" -verify_arch arm64
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
output="dist/store/FaceHugger-$version-$build.pkg"
productbuild --component "$app" /Applications --sign "$FACEHUGGER_STORE_INSTALLER_IDENTITY" "$output"
pkgutil --check-signature "$output"
shasum -a 256 "$output" > "$output.sha256"
printf 'Store-signed package prepared: %s\nNo upload or submission was performed.\n' "$output"

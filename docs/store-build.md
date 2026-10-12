# Mac App Store build

`project-store.yml` overlays the base project with sandbox entitlements, the `STORE_BUILD` compilation condition, and **version 1.0/build 7**. Build 7 is the signed and audited native build attached to the App Store draft (October 12, 2026). It is build 6 plus the privacy manifest (`Resources/PrivacyInfo.xcprivacy`) and the bubstack.dev privacy link. Build 5 added the dataset-card editor to the build-4 native backend; build 6 changes only the icon and in-app mascot artwork. Builds 4 and 5 remain uploaded but unattached. The uploaded build 3 remains a separate Python-runtime artifact with its existing non-exempt encryption facts.

Generate with `xcodegen generate --spec project-store.yml`. The generated `FaceHuggerStore.xcodeproj` is ignored by Git. The resource allowlist includes the asset catalog and the native wildcard matcher’s PSF license notice; Python bridge/runtime/requirements and historical third-party notices are not packaged. Legacy runtime bootstrap/policy source files are excluded from both app targets. There is no runtime embed phase or setup download in the intended native app.

## Permissions

The app retains outbound network and user-selected-folder read/write entitlements, with app-scoped bookmarks. The native implementation must retain selected-folder access through scanning and transfer lifetimes and restore bookmarks after relaunch. An old path-only queue item may require selecting its folder again. Credentials are entered in the app and stored in Keychain; a separate shell CLI login is not imported.

## Signing and packaging

Install Mac App Store application and installer signing identities/private keys and a matching provisioning profile in Keychain. These differ from Developer ID notarization credentials. Never store private keys in Git.

```sh
FACEHUGGER_STORE_APP_IDENTITY='3rd Party Mac Developer Application: Your Name (TEAMID)' \
FACEHUGGER_STORE_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: Your Name (TEAMID)' \
FACEHUGGER_STORE_PROFILE='Your installed profile name' \
FACEHUGGER_TEAM_ID='TEAMID' \
Scripts/package-store.sh
```

The script performs a clean universal Release build, then audits the exact bundle for forbidden legacy runtime resources, unexpected native executables, non-system dynamic dependencies, and selected Python/third-party crypto references. It verifies signature, sandbox/network entitlements, both architecture slices, and the embedded provisioning profile. Only a passing bundle is packaged and checksummed in `dist/store/`. Reports are in `.build/store-package/native-audit/`. There is no automatic upload, submission, or publication.

The audit is deliberately strict: even Xcode's Debug companion dylib fails it. Use a Release build. Dynamic dependency inspection cannot rule out statically embedded code by itself; source/link-input review remains necessary. See [native-backend-release.md](native-backend-release.md) for the complete gate.

## Evidence and remaining work

Prior sandbox probes, Python/HF test suites, completed upload screenshots, and build-3 live round trips are historical evidence for the prior engine. They are not proof of native build-4 behavior. Native live authentication/upload/browse/delete, multipart, cancellation and fresh-process resume, sandboxed selected-folder access and a four-file UI upload, and an audit of the expanded signed installer have passed. Clean-machine installation remains to be verified. Intel runtime execution is separate from having a valid x86_64 slice.

Build 3's uploaded screenshots and published privacy label remain in App Store Connect. Builds 4, 5, and 6 passed the native package audit and declare only OS-provided encryption. Build 5 added only a weak-linked FoundationModels dependency ([audit](verification/native-bundle-build5.json)); build 6 has the same dependencies ([audit](verification/native-bundle-build6.json)); the old French-filing work remains historical unless the owner proceeds with build 3. No legal exemption is asserted merely because the architecture is intended to use Apple system APIs.

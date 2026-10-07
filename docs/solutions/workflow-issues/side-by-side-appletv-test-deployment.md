---
title: Deploy a personal Apple TV test app beside official Swiftfin
date: "2026-10-04"
last_updated: "2026-10-07"
category: workflow-issues
module: Swiftfin tvOS device deployment
problem_type: workflow_issue
component: development_workflow
severity: medium
applies_when:
  - Installing a fork on Apple TV while retaining official App Store Swiftfin
  - Giving a development build a recognizable name without renaming package products
tags: [tvos, deployment, signing, bundle-identifier, xcode, swift-packages]
---

# Deploy a personal Apple TV test app beside official Swiftfin

## Context

The playback-refresh fix needed a physical Apple TV test without replacing the viewer’s official Swiftfin installation. The session successfully built, signed, installed, and launched a separate **Swiftfin Test** app; the viewer subsequently confirmed the playback fix worked with Jellyfin 10.11.11.

The failed naming attempt used command-line `PRODUCT_NAME="Swiftfin Test"` and `SWIFT_MODULE_NAME=Swiftfin`. Those overrides also reached package targets: the build reported duplicate package object, executable, and module outputs. Removing both overrides resolved that collision. This investigation is absent from the final playback implementation and regression tests.

The same session initially had a valid development certificate but no configured Xcode account. Automatic provisioning failed with `No Accounts` and `No profiles for … were found`. The physical Apple TV was also absent from the device list until pairing. Compilation alone was not installation readiness.

## Guidance

Keep application identity, visible naming, and package product naming separate:

- Give the test app its own bundle identifier. The repo’s default is `org.jellyfin.swiftfin` in `XcodeConfig/Shared.xcconfig:10`; contributor setup already supports overriding it for multiple installed builds.
- Change **CFBundleDisplayName** in a temporary copy of the tvOS Info.plist, rather than globally overriding **PRODUCT_NAME** or **SWIFT_MODULE_NAME**. The normal display name references the product name (`Swiftfin tvOS/Resources/Info.plist:5–6`), but the executable has its own setting (`:7–8`). The tvOS target’s Debug and Release build settings retain `PRODUCT_NAME = Swiftfin` in the committed `Swiftfin.xcodeproj/project.pbxproj:959` and `Swiftfin.xcodeproj/project.pbxproj:991` (local Xcode formatting can shift these lines).
- Give the test app its own URL scheme. The normal plist registers `swiftfin` and `jellyfin` (`Swiftfin tvOS/Resources/Info.plist:19–29`); the successful test build used only `swiftfin-playback-test`.
- Keep the personal team, temporary plist, derived data, and signing credentials outside shared source changes. Use the ignored development xcconfig or a temporary build project. Apply naming overrides to the app target where possible, especially when a scheme gains extensions or other bundled targets.
- Check the developer account, physical-device pairing, and provisioning before promising installation. Recheck the selected app’s entitlements whenever capabilities change; successful signing of an earlier build does not establish signing readiness for new capabilities.

### System-profile deployment and diagnostics

The profile-isolation investigation added three constraints absent from the earlier playback test:

- On the tested device, CLI process launches and app-data-container inspection selected the default profile's context even when another profile was visible in Control Center. A process ID or CLI container listing therefore does not identify the selected profile. Use remote launches and in-app harmless storage markers for acceptance. An attempted named-user CLI launch was unsupported in this setup.
- The entitlement is a three-part check: the source declaration, the provisioning profile's allowed capability, and the final signed executable's entitlements. A certificate alone does not grant the capability. Inspect the final signature and embedded profile locally; never commit either private signing material or extracted profile data. The repo declaration is `Swiftfin tvOS/Resources/Swiftfin.entitlements:7`, but entitlement presence alone does not prove correct runtime isolation.
- Pre-existing iCloud duplicate source files caused build collisions in the working checkout. Building an isolated snapshot of tracked sources, plus an explicit list of intended uncommitted feature files when needed, avoided the duplicates without deleting the viewer's unrelated files. Keep derived data and temporary signing or display-name edits outside the repo. Do not stage a directory wholesale to make the snapshot.

A signature-verification error from sandboxed tooling was contradicted by verification outside that boundary in this session. Recheck the identical artifact with authorized tooling before diagnosing a broken signature or weakening verification. Keep any resulting device logs, usernames, certificate identities, provisioning UUIDs, and local directory fingerprints out of learning documents.

## Why This Matters

A recognizable display name does not establish a separate installation. The distinct bundle ID is the essential separation; a distinct test URL scheme keeps test links distinguishable from the official app’s schemes. In this session, keeping the underlying product/module names unchanged avoided the observed package-output collisions while still showing **Swiftfin Test** on Apple TV.

The temporary build settings were removed from the checkout after deployment. Without this record, a future custom-feature deployment could repeat the global naming overrides or mistake a certificate and an unsigned build for a deployable app.

## When to Apply

Use this workflow for personal fork acceptance on Apple TV when the official client must remain available. For subsequent deployments intended to update the same test app, keep its bundle ID stable rather than selecting a fresh identity each time. This guidance does not establish that later feature capabilities are provisionable by the same team.

## Examples

The following example preserves the verified naming arrangement while replacing the personal installation identity:

| Setting | Example value |
| --- | --- |
| Bundle ID | `com.example.swiftfin.test` (illustrative; must match provisioning) |
| Display name | `Swiftfin Test` |
| Product/executable | `Swiftfin` |
| URL scheme | `swiftfin-playback-test` |

Adapt the bundle ID and signing team to the intended personal installation. Before installing, inspect the **built app**, not just the build command:

1. Read its processed Info.plist and verify the distinct `CFBundleIdentifier`, `CFBundleDisplayName`, and URL schemes.
2. Run `codesign --verify --deep --strict` on the app bundle and confirm a successful signed build.
3. Use `xcrun devicectl list devices` to select the paired physical Apple TV, checking that it is not the similarly named simulator. In this session the output explicitly distinguished **physical** and **simulated** devices.
4. Install that verified app bundle with `devicectl device install app`. For system-profile acceptance, open it with the physical remote after selecting the intended profile; do not use CLI process launch as proof of that profile's runtime context.

The signed build, installation, and launch succeeded in this session. The viewer’s confirmation establishes a working playback test on Jellyfin 10.11.11; it is not evidence that every planned playback scenario or the declared Jellyfin 12.0 baseline was tested.

## Related

- [Native storage switching diagnosis](tvos-profile-storage-switching-workaround.md): deployment success does not establish reliable automatic profile switching.

- [Contributor Xcode configuration](../../../Documentation/contributing.md#xcode-config): personal team and bundle-ID setup; this learning adds the package naming failure and separate deployment checks.
- [TestFlight signing setup](../../../Documentation/testflight_action.md#certificate-and-provisioning-profile): distribution signing is a separate workflow.

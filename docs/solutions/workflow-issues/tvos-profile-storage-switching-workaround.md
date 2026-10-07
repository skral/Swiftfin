---
title: Validate tvOS profile storage and use a controlled switching workaround
date: "2026-10-07"
category: workflow-issues
module: Swiftfin tvOS profile acceptance
problem_type: workflow_issue
component: development_workflow
severity: high
applies_when:
  - Testing system-profile isolation on physical Apple TV
  - A switched profile displays another Jellyfin account
retire_when: "A released tvOS update fixes incorrect storage persona selection; verify release notes and repeat the native marker probe on the affected device."
tags: [tvos, profiles, isolation, keychain, manual-testing, workaround]
---

# Validate tvOS profile storage and use a controlled switching workaround

## Context

On Apple TV 4K (third generation), tvOS 27.0, system-profile switching intermittently showed another profile's Jellyfin home screen. It happened during playback and ordinary browsing. Repeated successful switches were insufficient evidence of reliability.

A minimal SwiftUI probe removed Swiftfin sessions, navigation, image caches, and Jellyfin requests from the experiment. It wrote harmless profile labels and random markers into five stores: standard defaults, named defaults, Caches, temporary files, and ordinary keychain. After a clean reinstall, each of three profiles initially had separate markers. A later switch to the first profile started a new process but retained the third profile's home-directory fingerprint and all five markers. Application Support writes failed with a permission error and therefore provided no isolation evidence.

This establishes an incorrect native storage context on the tested installation, independent of Swiftfin account-selection logic. It does not establish Apple's internal root cause or universal failure on all devices. The system reported per-user preferences permitted even during failure; that capability flag and a changing process ID do not prove the correct user container was selected.

## Guidance

Use the physically verified manual workaround:

1. Force-close Swiftfin **before** changing the system profile.
2. Wait five seconds.
3. Change the profile from the Apple TV Home screen.
4. Open Swiftfin with the remote.
5. Confirm the Jellyfin account in Settings before browsing or playing.

The viewer confirmed separate logins and home screens, then repeated playback, pause, and switches in both directions with this sequence. Closing after switching, reinstalling, and repeated relaunches did not reliably prevent recurrence. The workaround is accepted for this installation; automatic foreground switching remains unverified as reliable.

Apple describes terminating and relaunching the app for the incoming user in [WWDC 2020](https://developer.apple.com/videos/play/wwdc2020/10645/). The app declares the modern user-management entitlement in `Swiftfin tvOS/Resources/Swiftfin.entitlements:7`. The entitlement permits the feature; it is not evidence that a particular runtime launch selected the correct storage.

Retain ordinary per-user keychain behavior for separate Jellyfin logins. Apple's [user-independent keychain option](https://developer.apple.com/documentation/security/ksecuseuserindependentkeychain) deliberately shares selected items across users; adding it would undermine this isolation goal.

## Why This Matters

A restarted process can consistently read the wrong profile's otherwise coherent data. Rebuilding navigation, clearing artwork, adding foreground reloads, or changing account-selection defaults cannot repair an incorrectly assigned native container. A home-directory fingerprint is diagnostic evidence of the current context, not a supported identifier for the profile selected in Control Center.

A native marker probe separates platform behavior from application behavior. Use fresh namespaces, read existing markers before changing them, and tag each profile only once; overwriting a marker while testing would hide the error. Never use real tokens, account names, user photos, device identifiers, or private directory paths in a committed report.

## When to Apply

Use this acceptance sequence after signing or entitlement changes, OS updates, clean installs, and playback lifecycle changes. Include account-free profiles as well as Apple-account profiles when available; do not infer reliable third-party isolation solely from their presence in the system switcher.

## Examples

Profile A starts with marker A; profile B starts with marker B. Switch back to A without pressing a marker button. A new process displaying marker B is a failure, even when the capability flag is true. With the controlled workaround, verify A restores A and B restores B, including repeated play/pause transitions.

Keep probe observations distinct from automated tests: simulator tests verify app policy, not physical tvOS persona assignment. The opt-in physical test is not evidence of a completed device run.

## Related

- [Developer reproduction of incorrect containers](https://community.firecore.com/t/user-switching-broken-tvos-26-4-update-fix-available-in-tvos-26-6/59339?page=3), including sample-app reproduction and force-close reports.
- [Developer reports on tvOS 27](https://community.firecore.com/t/user-switching-still-broken-on-tvos-27/60764); reports and affected models vary, so an earlier version's claimed fix is not proof for a later installation.
- [User-facing setup and workaround](../../../Documentation/common_issues.md).

---
title: Give each Apple TV profile a separate Jellyfin device identity
date: "2026-10-07"
category: integration-issues
module: Swiftfin tvOS Jellyfin session isolation
problem_type: integration_issue
component: api_layer
severity: high
symptoms:
  - Separate local profiles shared the same server device identity
  - Profile switching produced incorrect account state and occasional HTTP 401 responses
root_cause: config_error
resolution_type: code_fix
tags: [tvos, profiles, jellyfin, device-id, authentication]
---

# Give each Apple TV profile a separate Jellyfin device identity

## Problem

Separate local storage and tokens do not guarantee separate Jellyfin server sessions when profiles send the same client name and physical-device identifier.

## Symptoms

During device testing, distinct profile containers held different users and token fingerprints, but requests used the same vendor-derived device ID. Account-state anomalies and HTTP 401 responses prompted server-source inspection. The specific reason an earlier token was rejected was not proven.

## What Didn't Work

Local account restoration and credential isolation alone left the shared server identity intact. Conversely, fixing device identity did not fix later incorrect native-container selection: that separate platform failure reproduced without Jellyfin. These two failures need separate tests.

Do not conclude that logging in as a different user necessarily revoked the previous user's token; observed 401 responses alone do not establish that mechanism.

## Solution

On tvOS, use a persistent random UUID in the current profile's defaults rather than the hardware vendor UUID. `Shared/Services/UserSession/SystemProfileDeviceIdentity.swift:16` reuses a valid UUID or generates and stores one under a lock. `Shared/Extensions/JellyfinAPI/JellyfinClient.swift:27` supplies it to the tvOS device ID; the non-tvOS branch still uses the vendor identity.

The focused identity harness passed persistence and separation checks after merging the feature locally. The regression test in `Swiftfin tvOSTests/SystemProfileSessionTests.swift:52` checks different suites yield different IDs and reopening a suite retains its ID. Physical acceptance also confirmed distinct account screens with the controlled switching workaround.

## Why This Works

In [Jellyfin 10.11.11 SessionManager](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Emby.Server.Implementations/Session/SessionManager.cs#L449-L496), the active-session key combines application name and device ID. Reusing the key returns the same session object, whose user identity is then updated. Giving profiles different device IDs prevents that collision when native profile storage is correctly selected.

The UUID is profile-scoped, not a way to discover which profile the system switcher currently displays. If tvOS launches into the wrong container, it also reads that container's device UUID. Fixing server identity cannot compensate for that platform assignment.

## Prevention

Verify both boundaries independently: local profile markers and server request identity. Check different profiles produce different device IDs, and repeated launches of the same profile retain its ID. Do not regenerate an ID for every request or derive it from a display name. Log only safe diagnostic fingerprints during investigation; never commit real tokens, account names, device IDs, or private server URLs.

## Related Issues

- [Native storage switching diagnosis and manual workaround](../workflow-issues/tvos-profile-storage-switching-workaround.md).

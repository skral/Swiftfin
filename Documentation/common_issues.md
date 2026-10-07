# Common Issues

This document contains common Swiftfin issues, troubleshooting steps, and resolutions for items that come up frequently.

If your issue isn't here, please check our [existing issues](https://github.com/jellyfin/Swiftfin/issues) before opening a new one. For issues or questions about playback, see the [Players Documentation](players.md). For library support, see [Libraries Documentation](libraries.md).

---

## Before You Report

These four steps resolve many common issues or help narrow down unique issues from known ones:

| Step | Why |
|------|-----|
| **1. Update Swiftfin** | We are only able to support the current release which may already have a code fix for the issue you are experiencing. If you see a closed issue for your problem, but it's still not resolved on the latest release, please try using our [TestFlight](https://testflight.apple.com/join/SqNPfdxq) before reporting a new issue. |
| **2. Switch the player** <br>*Settings > Advanced > Video Player > Engine* | Each player is based on a different playback engine. Confirming which player(s) has an issue helps narrow the troubleshooting steps. |
| **3. Connect by direct `IP:port`** | If this works and your domain doesn't, the problem is your reverse proxy or network. |
| **4. Check the logs** <br>*Login Issues: Settings > Advanced > Logs* <br>*Other Issues: Settings > Logs* | These logs show network traffic and logs for Swiftfin. Identifying the failing decodes or packets that exist can help resolve network/proxy issues. |

---

## Playback

### Nothing Plays, but Browsing Works

Your library, posters, and metadata all load. Pressing play gives a black screen or a spinner. This issue is commonly caused by one of the following:

**Your reverse proxy is TLS 1.3 only.** libvlc only supports TLS **1.1 and 1.2**, so media playback fails while everything else works. NGINX has included 1.3 by default since 1.23.4, so this can appear after an update. Enable 1.2 alongside 1.3 (having both is fine) and libvlc will fall back to using the supported version. This is a libvlc limitation and is documented in the [Players Documentation](players.md).

**You entered `http` for an `https` server.** You can sign in and browse everything, but nothing plays. Swiftfin attempts to resolve this at login, but HSTS and redirects can mask the issue since some requests follow the redirect but media requests do not. Re-add the server with the correct scheme.

If neither applies, please test on a direct `IP:port` connection before reporting.

### HDR or Dolby Vision Looks Wrong

Purple casts, washed out color, or no tone mapping at all. Both players handle HDR differently and neither is perfect:

- **VLC** tone maps, but colorspace accuracy varies with content and device.
- **Native (AVPlayer)** needs Direct Play compatible MP4, and often Dolby Vision Profile 5 or 8.

Start by forcing the server to tone map instead of VLC and see if this resolves your issue. These settings can be enabled from:

*Settings > Advanced > Video Player > Playback Quality > HDR > Force Dolby Vision to Transcode*
*Settings > Advanced > Video Player > Playback Quality > HDR > Force HDR to Transcode*

Please see the notes in the [Players Documentation](players.md) before reporting, and include your file's media info from Jellyfin Web.

### Audio Out of Sync over AirPlay Speakers or HomePods

This is a [known SwiftVLC bug](https://code.videolan.org/videolan/VLCKit/-/issues/544) and tracked on Swiftfin [here](https://github.com/jellyfin/Swiftfin/issues/937). This item cannot be resolved by Swiftfin and requires a patch from VLC. As a workaround, please use the Native player for this output.

### Native Player Cannot Select Subtitles or Change Audio Tracks

The Native player is built on top of AVPlayer but has not yet been connected to the unified video player interface. Track selection is a known issue and is actively being worked on. In the meantime, please use the VLC player for this support.

### Unnecessary Transcoding or Remuxing

Swiftfin uses **Device Profiles** that can be manually adjusted based on your device and media. These settings can be found in **Settings > Advanced > Video Player > Playback Quality** where you can change to a different pre-made **Device Profile** or you can select **Custom** to build your own.

You can add a new profile to the existing ones that would keep all else the same but allows a specific format to **Direct Play**, or you can fully replace them all with **Custom** profiles.

These settings exist to enable newer, unverified configurations to work on your device. If you experience any issues when using **Custom Profiles**, please turn them off and use a pre-made configuration before creating an issue.

### Gesture Lock

To leave `Gesture Lock`, hold a single point on the screen until the `Gestures unlocked` notification appears at the top of the view to show that it has been unlocked.

---

## Connection

### No Local Servers Found

Automatic discovery uses UDP broadcast on port `7359` and this port cannot be changed. Start by ensuring that this port is accessible from your server and that your server and device are on the same network. mDNS and UDP broadcast must be available from your router. These are network configurations and outside the scope of Swiftfin. [Jellyfin forum or chat rooms](https://jellyfin.org/contact/) would be the best place for troubleshooting assistance for these types of issues.

### "The Internet Connection Appears to Be Offline"

Swiftfin can't reach the server but a browser on the same device can. Common causes:

- **Local Network permission is off.** Enable it in iOS Settings > Swiftfin.
- **Reverse Proxy or Custom Headers**, which Swiftfin does not currently support. See [Reverse Proxies](#reverse-proxies).
- **Stale iOS network cache**, usually after changing networks or during server maintenance. Restarting your device should be your first step in resolving this issue.

If the issue persists, please reach out with an issue and include your logs from Swiftfin found at *Settings > Logs*. If you are unable to login, these logs can be found at *Settings > Advanced > Logs*.

### "The Data Couldn't Be Read Because It Isn't in the Correct Format"

This is a generic error that means that Jellyfin sent information to Swiftfin in a format that was not expected. The usual culprits:

- A **`baseurl`** set on your server that isn't included in the address you entered, so we receive HTML instead of JSON.
- **Server plugins** that change API responses away from what the SDK expects.
- A **server version mismatch**. See [Server Compatibility](#server-compatibility).

*Settings > Advanced > Logs* will show which request failed. This should be included in any issues created to assist in troubleshooting.

### Reverse Proxies

Most connection problems that reach us are proxy configuration rather than Swiftfin. Please start from a configuration Jellyfin has vetted as Swiftfin should be compatible with standard configurations:

- [Caddy](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/caddy)
- [Nginx](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/nginx)
- [Apache](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/apache)
- [Traefik](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/traefik)
- [HAProxy](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/haproxy)

Beyond a working Jellyfin proxy, Swiftfin needs **TLS 1.2 available**, a certificate from a **trusted CA** at the OS level, and no filtering middleware in the request path. ModSecurity has been confirmed to block requests with a `403` while leaving browsers intact.

**The Swiftfin team is not able to troubleshoot custom or heavily modified proxy setups.** The Jellyfin team that works on Swiftfin are not experts on networking or proxies. These issues are best handled by the [Jellyfin forum or chat rooms](https://jellyfin.org/contact/). If your configuration differs from the documented ones, please reproduce the problem on a documented config or a direct `IP:port` connection before reporting.

When you do investigate, please read your **proxy's** logs as Jellyfin does not see requests that the proxy has rejected.

### 401 Error

This error means your authentication to your Jellyfin server is not valid. The most common reasons for this are:

- **Your password has changed**
- **Your device was removed from the Admin Dashboard**

To resolve this issue, go to *Settings > Sign Out* then use the Add button to re-add your same account back to Swiftfin. On enter, Swiftfin will provide you the option to **Replace** the existing login. Performing this action will swap out your authentication token while preserving your Swiftfin settings.

---

## Apple TV System Profiles

Swiftfin remembers a separate Jellyfin account for each Apple TV system profile. Select the adult system profile and sign in to its Jellyfin account, then select Kids and connect/sign in to the kids account. Returning to a configured system profile restores its selected account when its sign-out and local security settings allow it. Account-free Kids profiles require tvOS 26.2 or later.

The first launch after upgrading to system-profile support asks you to choose an account explicitly. Existing accounts exposed in the current profile can be selected; an empty profile uses the normal server connection and sign-in screens. Swiftfin does not copy legacy SQLite accounts or credentials into another profile.

To change the remembered Jellyfin account, sign out and select or add the desired account while that Apple TV profile is active. Explicit sign-out stays effective on subsequent launches. Sign out on close/background preferences still apply, and PIN-protected accounts require authentication before their home screen appears. If a saved token is missing, sign in again and choose Replace. If a required local PIN is missing, remove the saved account from that profile and add it again to create a new PIN.

Apple intends profile switches to terminate and relaunch Swiftfin with the incoming profile's storage. On the tested tvOS 27 installation, automatic switching intermittently relaunched apps with another profile's storage, even in a minimal app without Jellyfin. Reinstallation did not reliably prevent recurrence. Switching during playback stops that player; it does not resume under the incoming account. A final progress report may be interrupted by system termination. Jellyfin controls each account's library access and parental restrictions; Apple TV's profile switcher is not a parental lock for Swiftfin.

The verified manual workaround is to force-close Swiftfin **before** switching profiles, wait five seconds, switch the system profile from the Apple TV Home screen, then open Swiftfin with the remote. Confirm the Jellyfin account in Settings before browsing or playing. Closing the app after switching was insufficient in testing. This workaround passed repeated playback and profile-switch tests on the tested device; it does not establish that automatic switching is reliable on every tvOS installation.

For manual acceptance with that workaround, test adult → new Kids → sign in as the kids Jellyfin user → adult → Kids. Confirm the account, libraries, Continue Watching, and Next Up each time. Repeat switches from a detail page, playback, and the background; confirm that playback does not resume as the other user. Test PIN prompts, explicit sign-out, and an upgrade over the same installed app identity. Play an episode under each account and return to Home to check that Next Up and Continue Watching refresh. Physical-device storage isolation, artwork separation, and account-free Kids behavior remain required acceptance checks.

---

## Library and Media

### No Media After Signing In

Swiftfin filters by library **collection type**, not by the items inside. A library with a blank or unsupported type disappears entirely. Please set the correct type in Jellyfin.

See the [Libraries Documentation](libraries.md) for what is currently supported.

### tvOS Contains the Wrong Items Under "Movies"

On tvOS, the top level **Movies** and **Shows** sections group by *media type* across your whole server, not by your library named "Movies". Use **Media** to browse by library. This is working as intended, though we recognize it's confusing.

---

## Server Compatibility

Swiftfin is built against the latest OpenAPI specification produced by the Jellyfin Server Team. **Support is only guaranteed for the current stable Jellyfin release.** Running server pre-releases or legacy versions may result in issues. The compatible version can be found on the project [README](https://github.com/jellyfin/Swiftfin).

---

## Still Having Trouble?

For **configuration help** such as proxies, certificates, transcoding, networking, etc, please start at the [Jellyfin forum or chat rooms](https://jellyfin.org/contact/).

If you've found a reproducible bug in Swiftfin, please [open an issue](https://github.com/jellyfin/Swiftfin/issues/new/choose).

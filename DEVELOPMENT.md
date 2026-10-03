# Developer guide

For app usage, see [README.md](README.md). Coding agents should also read [AGENTS.md](AGENTS.md).

## Build the Mac app

From the repository root:

```sh
sh build-app.sh
open dist/Lantern.app
```

The script creates an ad-hoc signed local Apple Silicon app on the current development Mac. It is not notarized or App Store signed, and is not a portable installer with bundled media tools. The native SwiftPM backend works around this machine's Command Line Tools-only setup.

The image-generated app icon lives in `Resources/Lantern.png`. The build script uses macOS `sips` and `iconutil` to package standard and Retina icon sizes into the app's `Lantern.icns` file before signing.

To build an update without overwriting a running app, pass a separate output path, for example `sh build-app.sh "$PWD/dist/next/Lantern.app"`. Quit the old app before opening the updated copy when playback can be interrupted.

For subtitle inspection/extraction, the Mac adapter looks for FFmpeg and ffprobe in Homebrew's standard locations. The development machine's installed FFmpeg lacks libass/subtitles filtering; burn-in is not implemented in this build.

## Run tests

```sh
sh test.sh
```

This runs Swift Testing unit tests and a real-network Python integration test using temporary synthetic files. Integration uses `en0` and requires its active IPv4 LAN address; it briefly advertises a test server and shuts it down afterward.

Coverage includes byte ranges, catalogue filtering, XML, SOAP pagination/faults, actual file streaming, Samsung subtitle transport, event subscriptions, callback restrictions, and path/symlink isolation. The script supplies this Command Line Tools installation's Testing framework/plugin paths when necessary. Full Xcode installations use standard Swift Testing instead. Automated protocol checks do not establish compatibility with every TV or media format.

## Architecture

- `LanternCore`: Foundation, CryptoKit, Network.framework, and Darwin sockets. Implements the folder catalogue, SSDP discovery, HTTP streaming, SOAP ContentDirectory/ConnectionManager, GENA initial event subscriptions, and Samsung subtitle metadata. No AppKit, SwiftUI, or subprocess dependency.
- `LanternMac`: SwiftUI window/menu bar, folder chooser, sleep assertion, and a Mac-only FFmpeg adapter.
- `lantern-serve`: command-line integration harness: `lantern-serve FOLDER [INTERFACE-IP] [PORT]`.

HTTP byte ranges support seeking. Samsung `CaptionInfo.sec` headers and `sec:CaptionInfoEx` metadata expose external SRT files. Subtitle selections are stored in the `local.lantern.mac` UserDefaults domain; changes to source video size or modification time invalidate the cached selection.

## Network implementation and security

The HTTP listener binds to one selected IPv4 LAN address on TCP port 8200. Discovery uses UDP multicast `239.255.255.250:1900`; SSDP replies are limited to peers on the interface's subnet. Event callbacks are limited to the requesting peer, with redirects disabled. Notification responses are closed after their headers; an overall five-second resource timeout bounds callbacks that do not finish their headers.

Opaque IDs map to indexed files; request paths never become filesystem paths. The server rechecks file paths when serving media/subtitles to reject symlink substitutions, including links to unindexed files inside the selected folder. These protections do not replace network trust: the server intentionally has no authentication or TLS.

## Future iOS support

The package declares iOS 16+ support for the **core library**, but an iOS app/SDK build has not been implemented or verified. A future iOS target should depend only on `LanternCore`, not the Mac executable targets.

It needs a Files/document-picker or Photos import adapter, security-scoped file access, local-network usage text, and Apple's restricted multicast entitlement. iOS cannot use the Mac's `Process`/Homebrew FFmpeg adapter; use on-device media frameworks or deliberately licensed bundled libraries instead.

For iPhone-local videos, foreground serving is the realistic initial design: iOS generally suspends arbitrary servers in the background. For Mac-hosted videos, keep the Mac as the server and make the iPhone a browser/controller or optional downloader, rather than relaying the TV stream through the phone. Shared-Mac access/control APIs and an iOS UI remain future work; none are exposed now.

## References

- [Samsung 2025 media specifications](https://developer.samsung.com/smarttv/develop/specifications/media-specifications/2025-tv-video-specifications.html)
- [Apple local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple networking API guidance](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [UPnP AV specifications](https://openconnectivity.org/developer/specifications/upnp-resources/upnp/mediaserver4-and-mediarenderer3/)

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

`build-app.sh` optionally embeds `OPENSUBTITLES_API_KEY` from its environment into the output bundle's plist, before signing. No key is written to the source plist. For a local configured build, load the authorized Keychain item into that environment variable without printing it:

```sh
OPENSUBTITLES_API_KEY="$(security find-generic-password -a Lantern -s local.lantern.opensubtitles -w)" sh build-app.sh "$PWD/dist/next/Lantern.app"
```

The application key is intentionally extractable from a distributed desktop bundle; keeping it in Keychain/Actions secrets prevents source/history/log exposure, not extraction by recipients. Never print a configured bundle's full plist or commit a key.

## DMGs and GitHub Actions

```sh
sh build-dmg.sh 0.1.0
```

This builds in a fresh `.build/dmg.*` staging directory without touching `dist/Lantern.app`, then creates `dist/Lantern-0.1.0-arm64.dmg` and its `.sha256` checksum on an Apple Silicon Mac. The disk image contains the app, an Applications shortcut, and first-launch instructions. FFmpeg/ffprobe are not bundled. Staging is retained for inspection; an existing DMG is not overwritten. The optional version defaults to `Resources/Info.plist` and is applied to the packaged app, not the source plist.

The workflow uses the Apple Silicon `macos-15` runner with Xcode 16.4. Pushes to `main` and pull requests run unit tests, build the app/DMG, verify the ad-hoc signature and image, and upload artifacts for 14 days. LAN integration tests remain local; CI does not validate real TV discovery or playback.

Only push builds receive the repository's `OPENSUBTITLES_API_KEY` Actions secret, scoped to the packaging step. Pull-request builds never receive it, including same-repository PRs. Tests use synthetic responses and no provider credentials or download quota.

Pushing an exact `vMAJOR.MINOR.PATCH` tag (for example `v0.1.0`) additionally publishes a **prerelease** with the DMG and SHA-256 checksum. Tag versions must contain three numeric components. The release job alone receives repository write permission. No Apple signing credentials are configured: downloads are unnotarized and the release notes explain Gatekeeper approval. Publishing a tag is a separate, explicit release action; creating these files does not publish anything.

## Run tests

```sh
sh test.sh
```

This runs Swift Testing unit tests and a real-network Python integration test using temporary synthetic files. Integration uses `en0` and requires its active IPv4 LAN address; it briefly advertises a test server and shuts it down afterward.

Use `sh test.sh --unit-only` for the LAN-independent checks used in CI. Playback-activity tests use a loopback HTTP server and a shortened grace period to verify expiry, renewed browsing/streaming, overlapping transfers, and stop cleanup without waiting 15 minutes.

Coverage includes byte ranges, catalogue filtering, XML, SOAP pagination/faults, actual file streaming, Samsung subtitle transport, event subscriptions, callback restrictions, and path/symlink isolation. The script supplies this Command Line Tools installation's Testing framework/plugin paths when necessary. Full Xcode installations use standard Swift Testing instead. Automated protocol checks do not establish compatibility with every TV or media format.

## Architecture

- `LanternCore`: Foundation, CryptoKit, Network.framework, and Darwin sockets. Implements the folder catalogue, SSDP discovery, HTTP streaming, SOAP ContentDirectory/ConnectionManager, GENA initial event subscriptions, and Samsung subtitle metadata. No AppKit, SwiftUI, or subprocess dependency.
- `LanternMac`: SwiftUI window/menu bar, folder chooser, sleep assertion, a Mac-only FFmpeg adapter, local SRT language detection, and an OpenSubtitles client.
- `lantern-serve`: command-line integration harness: `lantern-serve FOLDER [INTERFACE-IP] [PORT]`.

HTTP byte ranges support seeking. Samsung `CaptionInfo.sec` headers and `sec:CaptionInfoEx` metadata expose external SRT files. Subtitle selections are stored in the `local.lantern.mac` UserDefaults domain; changes to source video size or modification time invalidate the cached selection.

The Mac app watches the selected folder recursively with FSEvents, coalesces changes for one second, and defers rescanning while media work or server startup is busy. Automatic scans replace the catalogue on the server queue without replacing its listener or closing active streams. Cached subtitle selections are revalidated during the scan. Subsequent TV Browse requests see additions and removals; an existing TV view is not forced to reload. Manual refresh retains its stop/resume behavior. Containers containing folders sort all children by modification date, newest first, with natural-name ties; video-only containers keep natural filename order for episodes.

### Cooperative download completion

A dedicated download subtree opts into ready-only discovery with `.dl-state/v1/root.json` containing `{"version":1,"policy":"ready-only"}`. The presence of `.dl-state` makes that subtree managed even when its metadata is missing, malformed, unsupported, or a symlink. Unmanaged siblings retain normal discovery. Selecting a folder inside a managed subtree does not bypass its ancestor's policy. Lantern only reads this state; it never certifies downloads, removes guards, or changes original media.

Each `ready-<attempt>-<gid>.json` contains `version: 1`, a 32-character lowercase hexadecimal `attempt`, a 16-character lowercase hexadecimal `gid`, and a nonempty `files` array. Each member has an exact root-relative `path`, `size`, and `mtime_ns`; the latter two are canonical unsigned decimal strings. Filenames must agree with IDs. Paths cannot be absolute, contain empty/dot/parent components or NUL, traverse symlinks, or enter `.dl-state`. Duplicate paths within a record are invalid. Additional object keys are ignored. Documents are bounded to 8 MiB each. Invalid final ready records block the subtree; stale or missing individual payloads only disqualify those files. `.tmp-` publication files and unrelated producer-private state never grant readiness.

Any `pending-*.json`, even malformed, blocks all entries in that managed subtree until every pending guard is removed by the producer. The producer publishes a guard before starting/resuming writes, publishes ready records only from authoritative payload-completion events, and publishes readiness before removing its own guard. Records are flushed and atomically renamed into place. File size and nanosecond modification time must match exactly; stable size or absence of `.aria2` is not proof of completion. A valid completed torrent remains eligible during seeding even if its control file still exists.

Scans cache parsed metadata only for that scan and recheck pending state after validating file identity. New media/subtitle requests independently revalidate completion state, without waiting for a watcher refresh. Automatic scans withdraw guarded/stale entries but retain queued subtitle retries for temporarily hidden videos. Already-open streams are not revoked, and the cooperative protocol cannot eliminate every cross-process check/open race. No download completion is inferred for pre-existing unmarked files inside managed roots.

English readiness additionally records the selected SRT path, size, and modification time in UserDefaults. An unchanged verified video/SRT pair bypasses ffprobe; new or invalidated pairs follow normal inspection. Daily-quota deferrals persist a queue of video IDs and a retry date. A one-minute app timer retries due entries in the current library, without stopping sharing. Provider `reset_time_utc` values receive a one-minute safety margin; absent, invalid, or expired timestamps fall back to 24 hours. Cancellation persists a pause until the next manual preparation. Automatic retries update only indexed subtitle URLs on the server queue and increment the catalogue revision without replacing the HTTP listener or closing active streams. They do not force an existing TV player to reload subtitles.

Successful ffprobe track inspections are cached separately under `Lantern/Inspection-v1` in the user's caches directory, keyed by video path ID, size, and modification time. Unchanged videos reuse those results across runs and app restarts, including videos that still need English subtitles. The first inspection populates the cache; changed files are probed again. Invalid cache entries are replaced, probe failures are not cached, and files that change during inspection are rejected. Cache writes are best-effort and never modify originals. This caches track metadata only, not subtitle-search failures or download plans, so retry and quota behavior is unchanged.

Valid nonempty media GET/HEAD requests trigger Mac-side preparation for that video. The server defers only that response, never its shared queue, and gives a preparation attempt one five-second deadline shared by HEAD, GET, and range requests. After the deadline, requests proceed without a new subtitle header while the worker continues; a late success updates subsequent requests. Responses are rebuilt after waiting to revalidate catalogue membership, completion guards, paths, and ranges. Browse, invalid ranges, and unrelated routes do not trigger preparation. Attempts are deduplicated for the sharing session and invalidated by changed video/subtitle identity or explicit subtitle updates. Already-open streams remain untouched.

The Mac adapter queues requests behind its existing serial media work and uses the same preparation path for a selected video, on-demand work, and quota retries. No subtitle action stops sharing. Explicit track choices record a source/subtitle fingerprint in `selectedSubtitleReady` and bypass automatic English replacement while unchanged; selected-video **Find English Subtitles** clears that override. Cancellation pauses queued automatic work, not playback. Automatic failures go to Activity instead of presenting modal alerts.

Only a manual selected-video search can open the fallback picker after `noMatch`. It infers a title and S/E numbers from the basename, strips common release suffixes, and sends those editable fields through the provider's `query`, `season_number`, and `episode_number` parameters. The first result page is shown; empty results can be searched again with edited fields. Only full English, non-translated, single-file candidates are offered, with release, feature, SDH, and uploader details. No candidate is preselected or downloaded automatically. An explicit file ID goes through the existing bounded download/SRT validation pipeline, bypassing the cached automatic choice. The picker retains its original video and source identity even if library selection changes; changed videos are rejected before download and again before publication. Successful choices use `selectedSubtitleReady` and update the live catalogue. Manual quota failures retain the open picker but do not add an arbitrary choice to the fingerprint-based retry queue. The LAN server and automatic fingerprint-only behavior are unchanged.

The HTTP server reports playback activity from nonempty video file-body transfers (including byte ranges) and successful ContentDirectory Browse responses. HEAD, errors, subtitles, discovery, and routine status requests do not count. It holds activity across simultaneous requests and a 15-minute grace period after the last qualifying request closes; new activity restarts that grace period. Stop/failure cancels it immediately. The Mac adapter holds a sleep assertion only during this activity. This tracks delivery to the TV, not actual playback or buffered content, and does not override lid-close/manual sleep. A TV's automatic Browse requests can also extend the grace period.

## Network implementation and security

The HTTP listener binds to one selected IPv4 LAN address on TCP port 8200. Discovery uses UDP multicast `239.255.255.250:1900`; SSDP replies are limited to peers on the interface's subnet. Event callbacks are limited to the requesting peer, with redirects disabled. Notification responses are closed after their headers; an overall five-second resource timeout bounds callbacks that do not finish their headers.

Opaque IDs map to indexed files; request paths never become filesystem paths. The server rechecks file paths when serving media/subtitles to reject symlink substitutions, including links to unindexed files inside the selected folder. These protections do not replace network trust: the server intentionally has no authentication or TLS.

The separate outbound subtitle client runs sequentially on the media worker. Automatic downloads require explicit OpenSubtitles hash matches and reject forced/translated/multi-file/conflicting-feature results. Manual fallback candidates require explicit user selection instead of a hash match. Both paths bound responses to 8 MB and use ephemeral HTTPS sessions with request/resource timeouts. API requests cannot redirect; download redirects stay on HTTPS OpenSubtitles.com hosts and never carry the application key. Quota/rate-limit/service failures block further online attempts in that batch. Successful downloads use the same source-sensitive cache as extracted subtitles, with a `download` suffix. The custom LAN HTTP server is unchanged by this integration.

## Future iOS support

The package declares iOS 16+ support for the **core library**, but an iOS app/SDK build has not been implemented or verified. A future iOS target should depend only on `LanternCore`, not the Mac executable targets.

It needs a Files/document-picker or Photos import adapter, security-scoped file access, local-network usage text, and Apple's restricted multicast entitlement. iOS cannot use the Mac's `Process`/Homebrew FFmpeg adapter; use on-device media frameworks or deliberately licensed bundled libraries instead.

For iPhone-local videos, foreground serving is the realistic initial design: iOS generally suspends arbitrary servers in the background. For Mac-hosted videos, keep the Mac as the server and make the iPhone a browser/controller or optional downloader, rather than relaying the TV stream through the phone. Shared-Mac access/control APIs and an iOS UI remain future work; none are exposed now.

## References

- [OpenSubtitles search parameters](https://github.com/opensubtitles/mcp.opensubtitles.com#1-search_subtitles)
- [Samsung 2025 media specifications](https://developer.samsung.com/smarttv/develop/specifications/media-specifications/2025-tv-video-specifications.html)
- [Apple local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple networking API guidance](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [UPnP AV specifications](https://openconnectivity.org/developer/specifications/upnp-resources/upnp/mediaserver4-and-mediarenderer3/)

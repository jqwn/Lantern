# Troubleshooting Lantern

For setup and everyday use, see [README.md](README.md).

Playback has been reported working on a 2025 Samsung 65-inch QLED. Lantern is an early local build, not a DLNA-certified product; compatibility with other TVs and media formats is not guaranteed.

## macOS blocks the first launch

Packaged builds are for Apple Silicon Macs running macOS 13 or later. Open the DMG, drag **Lantern.app** to **Applications**, eject the image, then open the app from Applications. Quit an older copy before replacing it, when playback can be interrupted.

Lantern is ad-hoc signed, **not Developer ID signed or notarized by Apple**. A downloaded DMG does not bypass Gatekeeper. If macOS blocks the first launch and you trust the download, go to **System Settings → Privacy & Security → Open Anyway** after attempting to open it, then confirm. macOS normally remembers that exception, but an update may require approval again. Managed Macs may prohibit it. Do not disable Gatekeeper globally. See [Apple's instructions](https://support.apple.com/en-au/102445).

## The TV cannot find Lantern

- Confirm **Start Sharing** is on and the Mac and TV are on the same home network.
- Choose the Mac's active Wi-Fi or Ethernet interface in Lantern. Allow macOS Local Network access and incoming connections if prompted.
- On the tested Samsung TV, restarting the TV after enabling sharing was needed before Lantern appeared. Leave sharing enabled, restart the TV, and check **Connected Devices / Sources** again. This may not be necessary every time or on every TV.
- Guest-network/client isolation, VPNs, host firewalls, and multicast filtering can prevent discovery. Lantern does not change firewall or router settings.
- Before changing networks, stop sharing. Then use **Refresh Networks**, select the new interface, and start again.

If sharing cannot start, another app may be using TCP port 8200. Lantern reports the error rather than taking over that service. **Activity** shows discovery and playback requests and can help distinguish a discovery problem from a playback problem.

## Subtitle preparation failed

Open **Activity** for the file-specific error. The batch can fail for some files while succeeding for others. Successfully prepared subtitles remain available, and a preparation failure does not prevent ordinary streaming of playable videos.

FFmpeg and ffprobe must be installed for inspection and extraction; they are not bundled with Lantern. Ordinary video sharing does not need them. A media-tool process receives a termination request after two minutes. A malformed or incomplete video can fail before its subtitle tracks are readable; verify that file in your download app or another player rather than changing the original through Lantern.

Playback-triggered preparation waits at most five seconds before serving the video without newly prepared subtitles. Preparation continues in the background; reopen the video after it finishes. **Prepare English** works on the selected video only, and all subtitle preparation keeps sharing running. **Cancel After Current Video** lets the current operation finish and pauses further automatic preparation and queued retries until **Prepare English** is clicked again. Manual library refresh still restarts active sharing.

## Subtitles do not appear or look different

- Enable subtitles in the TV player's options.
- A separate subtitle file should have the same base name as the video, for example `Example.mkv` and `Example.srt`.
- For embedded subtitles, select a video, choose its text track, and click **Use on TV**. Selections persist across launches, but the TV may still prioritise its embedded tracks.
- SubRip, ASS/SSA, WebVTT, and other text formats supported by FFmpeg can be extracted. ASS styling is lost when converted to SRT.
- PGS/VobSub image subtitles are not converted or OCR'd. This build does not burn subtitles into the video.
- If the TV caches old subtitle information, reopen Lantern in the TV's source browser after preparing subtitles.

Automatic preparation and **Prepare English** prefer full English text tracks over forced/foreign-dialogue-only tracks. SDH tracks are also usable. Track language and forced flags depend on the file's metadata; missing or inaccurate tags cannot always be resolved automatically. Existing external SRT language is checked locally; short or uncertain text is left for review rather than assumed English. **Use on TV** remains an explicit choice of any available text track and is not replaced automatically while the video/subtitle pair is unchanged.

When no usable local English text subtitle is available, preparation searches OpenSubtitles using its file-hash fingerprint. It downloads only English, non-forced, non-machine/AI-translated results explicitly matched to that fingerprint, with one subtitle file and no conflicting movie/episode identities. It does not guess from filenames. Provider metadata can still be wrong, so a match is not a guarantee of perfect timing.

**Activity** and the per-video status explain unresolved items. No match means nothing is downloaded. Repeated TV requests share a preparation attempt instead of repeatedly downloading. For an unresolved video, select it and click **Prepare English** to retry manually. Downloads over the daily quota retry automatically after reset while Lantern is open and awake. Anonymous access permits 5 downloads per day per public IP; other apps sharing that IP may use the same allowance. This build does not provide account sign-in for a higher quota.

Official branch/tag builds include Lantern's developer API key. Pull-request and unconfigured source builds omit it; these can extract subtitles but report that online downloads are unavailable. No end-user API-key setup is required for official builds. Downloads are limited to 8 MB, must be valid UTF-8 SRT, and go into the cache rather than beside your originals.

## Unsupported video, missing sound, or stuttering

Lantern does not convert video or audio. The TV receives the original streams and must support their codecs. DTS, TrueHD, or other unsupported audio may require separate conversion; Lantern warns when those audio tracks are detected.

4K/HDR is passed through unchanged. Smooth playback depends on the TV's capabilities and the network's throughput. A file extension alone does not establish compatibility: two MKV files can contain different video and audio formats.

## Keeping the library available

Lantern starts as a menu-bar app. **Show Lantern** opens its window and shows it in the Dock and ⌘Tab. Closing the last Lantern window hides the Dock icon again but leaves sharing running. Its menu-bar icon also provides start/stop controls and **Quit Lantern**. Sharing does not start automatically or install a login/background service. Quit Lantern to stop it.

Leaving sharing enabled does not prevent sleep. Lantern prevents idle system sleep while the TV browses the library or receives video, and for 15 minutes after that activity ends. Each successful library Browse request or video transfer restarts the grace period. Discovery, routine status/HEAD checks, and subtitle downloads do not count. A TV that automatically browses in the background can extend the grace period. Stopping sharing releases sleep prevention immediately.

Wake the Mac before browsing or playing on the TV. You may need to reopen the TV's source browser afterward. Lantern observes transfers, not the TV's exact play/pause state: a long pause or more than 15 minutes of fully buffered playback can allow the Mac to sleep. The display can turn off, but closing the lid or manually putting the Mac to sleep may still interrupt playback.

Use **Refresh** after adding, deleting, or replacing videos. Do this before playback because refreshing an active library restarts sharing.

Folders appear before videos in DLNA browsing. Folders use their own filesystem modification date, newest first, with filename order for ties. Videos use natural filename order, so E01, E02, and E10 stay in sequence regardless of their dates. A folder's date is not a recursive "newest video" date and can be preserved by copying tools; it is read again on refresh. A TV that applies its own sort may override the server order.

## What is shared and stored

Only supported videos in the selected folder, matching subtitles, and explicitly prepared subtitle files are advertised. Hidden files, symlink entries, unrelated file types, and empty folders are excluded.

Prepared subtitles are stored in `~/Library/Caches/Lantern/Subtitles`; originals are never altered. This cache is separate from your video folder. Changes to the source video's size or modification time invalidate its saved subtitle selection.

Online preparation sends OpenSubtitles a file-size-based fingerprint calculated locally from the video's first and last 64 KB. It never uploads those bytes, the movie, or its filename/path. OpenSubtitles also sees the request's public IP and Lantern's application key. No online request is made just by browsing or sharing.

There is no authentication or encryption. Anyone who can reach the server can browse the shared library while sharing is on. Use a trusted home network, not public Wi-Fi; do not port-forward Lantern or expose it to the internet.

The current app is for Mac. An iPhone version is planned but is not included.

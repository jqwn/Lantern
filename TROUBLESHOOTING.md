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

Whole-library preparation can take time. **Cancel After Current Video** stops the batch between files. Preparation stops active sharing and restarts it afterward, so prepare before watching. Refreshing the library also restarts active sharing.

## Subtitles do not appear or look different

- Enable subtitles in the TV player's options.
- A separate subtitle file should have the same base name as the video, for example `Example.mkv` and `Example.srt`.
- For embedded subtitles, select a video, choose its text track, and click **Use on TV**. Selections persist across launches, but the TV may still prioritise its embedded tracks.
- SubRip, ASS/SSA, WebVTT, and other text formats supported by FFmpeg can be extracted. ASS styling is lost when converted to SRT.
- PGS/VobSub image subtitles are not converted or OCR'd. This build does not burn subtitles into the video.
- If the TV caches old subtitle information, reopen Lantern in the TV's source browser after preparing subtitles.

Preparation extracts existing text only: it does not find new subtitles, translate them, or modify the original video.

## Unsupported video, missing sound, or stuttering

Lantern does not convert video or audio. The TV receives the original streams and must support their codecs. DTS, TrueHD, or other unsupported audio may require separate conversion; Lantern warns when those audio tracks are detected.

4K/HDR is passed through unchanged. Smooth playback depends on the TV's capabilities and the network's throughput. A file extension alone does not establish compatibility: two MKV files can contain different video and audio formats.

## Keeping the library available

Lantern starts as a menu-bar app. **Show Lantern** opens its window and shows it in the Dock and ⌘Tab. Closing the last Lantern window hides the Dock icon again but leaves sharing running. Its menu-bar icon also provides start/stop controls and **Quit Lantern**. Sharing does not start automatically or install a login/background service. Quit Lantern to stop it.

Leaving sharing enabled does not prevent sleep. Lantern prevents idle system sleep while the TV browses the library or receives video, and for 15 minutes after that activity ends. Each successful library Browse request or video transfer restarts the grace period. Discovery, routine status/HEAD checks, and subtitle downloads do not count. A TV that automatically browses in the background can extend the grace period. Stopping sharing releases sleep prevention immediately.

Wake the Mac before browsing or playing on the TV. You may need to reopen the TV's source browser afterward. Lantern observes transfers, not the TV's exact play/pause state: a long pause or more than 15 minutes of fully buffered playback can allow the Mac to sleep. The display can turn off, but closing the lid or manually putting the Mac to sleep may still interrupt playback.

Use **Refresh** after adding, deleting, or replacing videos. Do this before playback because refreshing an active library restarts sharing.

## What is shared and stored

Only supported videos in the selected folder, matching subtitles, and explicitly prepared subtitle files are advertised. Hidden files, symlink entries, unrelated file types, and empty folders are excluded.

Prepared subtitles are stored in `~/Library/Caches/Lantern/Subtitles`; originals are never altered. This cache is separate from your video folder. Changes to the source video's size or modification time invalidate its saved subtitle selection.

There is no authentication or encryption. Anyone who can reach the server can browse the shared library while sharing is on. Use a trusted home network, not public Wi-Fi; do not port-forward Lantern or expose it to the internet.

The current app is for Mac. An iPhone version is planned but is not included.

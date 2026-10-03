# Lantern

A native Mac app that shares a selected video folder with a DLNA/UPnP TV. No account, cloud service, upload, analytics, or phone relay. Playback has been reported working on a 2025 Samsung 65-inch QLED; this is an early local build, not a DLNA-certified product.

[Developer guide](DEVELOPMENT.md) · [Coding-agent instructions](AGENTS.md)

## Watch videos on your TV

1. Open **Lantern.app**. In the source checkout, the built app is in `dist/Lantern.app`; if it has not been built yet, see [Build the Mac app](DEVELOPMENT.md#build-the-mac-app).
2. The default folder is `~/Downloads/Videos`. Use **Choose Folder…** to share a different folder.
3. Connect the Mac and TV to the same trusted home network. Choose the Mac's Wi-Fi/Ethernet interface. Allow macOS Local Network access and incoming connections if prompted.
4. Click **Start Sharing**. On the TV, look under **Connected Devices / Sources → Lantern**. Menu names vary by model.
5. Choose a video. Enable subtitles in the TV player's options if needed.
6. Keep the Mac's lid open. Lantern prevents idle system sleep while sharing, but cannot override closing the lid or manual sleep.

**Samsung TV discovery tip:** on the Samsung TV used to test Lantern, restarting the TV after enabling sharing was needed before the Lantern entry appeared. If you cannot see Lantern, leave **Start Sharing** enabled on the Mac and restart the TV, then check **Connected Devices / Sources** again. This may not be necessary on every TV or every time.

The menu-bar icon provides start/stop controls. Sharing does not start automatically or install a login/background service. Quit Lantern to stop it. Use **Refresh** after adding or deleting videos. Before switching networks, stop sharing; then refresh networks and start again.

## Subtitles

**If subtitles already work on your TV, you do not need to prepare them.** Lantern streams the original video and its embedded subtitle tracks unchanged. A separate `.srt` file with the same name as the video is also detected automatically.

- **Prepare English for Library** scans all videos for existing embedded English text subtitles and extracts them into separate SRT files that the TV may recognise more reliably.
- **Use on TV** prepares the subtitle track selected for an individual video, including other languages. Selections persist across app launches, although the TV may still prioritise its embedded tracks.
- Preparation does **not** download subtitles, translate them, or burn text into the picture. It saves extracted subtitles in the Mac's cache and never changes the original videos.
- Preparation requires FFmpeg and ffprobe; ordinary sharing does not. These tools are not bundled with the app.
- Whole-library preparation can take time. **Cancel After Current Video** stops the batch between files.

**Prepare subtitles before watching:** preparation stops sharing while it runs, then restarts it if sharing was previously on. Refreshing the library also restarts active sharing. If the TV caches old subtitle information, reopen Lantern in the TV's source browser.

## Playback limits and troubleshooting

- **TV cannot find Lantern:** check that sharing is on and both devices are on the same home network. Guest-network isolation, VPNs, firewalls, or multicast filtering can prevent discovery. Lantern does not change firewall or router settings.
- **Subtitle preparation failed:** open **Activity** for the file-specific errors. Files successfully prepared remain available; a preparation failure does not prevent ordinary video streaming. Each media-tool process has a two-minute timeout.
- **Subtitles do not appear:** enable them in the TV's playback options. Text formats such as SubRip, ASS/SSA, and WebVTT can be extracted; ASS styling is lost when converted to SRT. PGS/VobSub image subtitles are not converted or OCR'd.
- **Unsupported format or missing audio:** this build does not convert video/audio or burn in subtitles. DTS, TrueHD, or other unsupported TV codecs may need separate conversion. The app warns when these audio tracks are detected.
- **4K/HDR playback:** the original stream is passed through unchanged. Compatibility and smooth playback depend on the TV and network throughput.
- **Sharing cannot start:** another app may already be using TCP port 8200. Lantern reports the error rather than taking over that service.

## Privacy and local files

Only supported videos in the selected folder, matching subtitles, and explicitly prepared subtitle files are advertised. Hidden files, symlink entries, unrelated file types, and empty folders are excluded.

There is **no authentication or encryption**: anyone who can reach the server can browse the shared library while sharing is on. Use a trusted home network, not public Wi-Fi. Do not port-forward Lantern or expose it to the internet.

Prepared subtitles are stored in `~/Library/Caches/Lantern/Subtitles`. Original files are never altered. An iPhone app is planned but is not available in this build.

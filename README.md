# Lantern

A native Mac app that shares local videos with a DLNA/UPnP TV. No account required. Videos stay on your Mac—no uploads or phone relay.

## Quick start

For a packaged build, open the DMG, drag **Lantern.app** to **Applications**, and eject the disk image. Builds are for **Apple Silicon, macOS 13+**, and are **not notarized**; see [first-launch guidance](TROUBLESHOOTING.md#macos-blocks-the-first-launch).

1. Open **Lantern.app** and choose your video folder. The default is `~/Downloads/Videos`.
2. Connect the Mac and TV to the same home network. Allow local-network access and incoming connections if macOS asks.
3. Click **Start Sharing** if sharing is off.
4. On the TV, open **Connected Devices / Sources → Lantern** and choose a video.
5. Lantern keeps the Mac awake while the TV browses or streams, and for 15 minutes afterward. Otherwise it can sleep normally; wake it before watching again. Use **Stop Sharing** or quit Lantern when finished.

**Samsung tip:** if Lantern does not appear, leave sharing on and restart the TV. This was needed on the Samsung TV tested; other TVs may discover it immediately.

## Subtitles

Lantern automatically prepares English subtitles when your TV requests a video: it reuses ready subtitles, extracts an English text track, or downloads a confident OpenSubtitles match. Playback waits at most **five seconds**. If preparation takes longer, the video starts without newly prepared subtitles; reopen it afterward to pick them up. Existing embedded subtitles remain available to the TV.

- **Prepare English** prepares only the selected video ahead of playback.
- **Use on TV** prepares a selected subtitle track for one video.

Preparation requires FFmpeg/ffprobe, which are not bundled. Downloads require a matching video fingerprint; uncertain matches are left unresolved. Anonymous downloads are limited to 5 per day per IP. Lantern never translates subtitles or changes your originals.

Verified English subtitles are remembered across restarts. Later preparation skips unchanged, ready videos before inspecting their tracks; changed videos or changed/missing subtitles are checked again.

Downloads over the daily limit are **queued**, not failed. Lantern remembers the queue and retries after the provider's reset time while the app is open and the Mac is awake, including after reopening it. If no usable reset time is provided, it waits 24 hours. You may need to reopen a video on the TV to see newly prepared subtitles. Cancelling preparation pauses automatic preparation and retries until you select a video and click **Prepare English** again.

**Sharing stays on** during all subtitle preparation. An explicit **Use on TV** track choice is preserved while that video/subtitle pair is unchanged; **Prepare English** switches back to English preparation for the selected video.

## Having trouble?

- **Lantern is missing:** check the network and try the Samsung restart tip above.
- **Subtitle preparation failed:** open **Activity** for the reason; other videos and successfully prepared subtitles can still work.
- **Unsupported video or no sound:** Lantern streams files unchanged, so the TV must support their formats.

See the [troubleshooting guide](TROUBLESHOOTING.md) for more detail.

## Privacy

Use a **trusted home network**. Sharing has no password or encryption; anyone who can reach Lantern can browse the shared library while it is on. Do not expose it to the internet or forward router ports to it. Original files stay unchanged.

English preparation contacts OpenSubtitles only when a download is needed, sending a video fingerprint—not the video, filename, or folder path. Normal sharing stays local.

---

[Developer guide](DEVELOPMENT.md) · [Coding-agent instructions](AGENTS.md)

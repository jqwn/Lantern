# Lantern

A native Mac app that shares local videos with a DLNA/UPnP TV. No account, cloud service, uploads, or phone relay.

## Quick start

For a packaged build, open the DMG, drag **Lantern.app** to **Applications**, and eject the disk image. Builds are for **Apple Silicon, macOS 13+**, and are **not notarized**; see [first-launch guidance](TROUBLESHOOTING.md#macos-blocks-the-first-launch).

1. Open **Lantern.app** and choose your video folder. The default is `~/Downloads/Videos`.
2. Connect the Mac and TV to the same home network. Allow local-network access and incoming connections if macOS asks.
3. Click **Start Sharing**.
4. On the TV, open **Connected Devices / Sources → Lantern** and choose a video.
5. Lantern keeps the Mac awake while the TV browses or streams, and for 15 minutes afterward. Otherwise it can sleep normally; wake it before watching again. Use **Stop Sharing** or quit Lantern when finished.

**Samsung tip:** if Lantern does not appear, leave sharing on and restart the TV. This was needed on the Samsung TV tested; other TVs may discover it immediately.

## Optional subtitles

If subtitles already work, no preparation is needed. Existing embedded subtitles and same-name `.srt` files are shared automatically.

- **Prepare English for Library** extracts existing English text subtitles for the TV.
- **Use on TV** prepares a selected subtitle track for one video.

Preparation requires FFmpeg/ffprobe, which are not bundled. It does not download or translate subtitles, and never changes your originals.

**Prepare before watching:** preparation stops sharing until it finishes or is cancelled. Sharing then resumes if it was previously on.

## Having trouble?

- **Lantern is missing:** check the network and try the Samsung restart tip above.
- **Subtitle preparation failed:** open **Activity** for the reason; other videos and successfully prepared subtitles can still work.
- **Unsupported video or no sound:** Lantern streams files unchanged, so the TV must support their formats.

See the [troubleshooting guide](TROUBLESHOOTING.md) for more detail.

## Privacy

Use a **trusted home network**. Sharing has no password or encryption; anyone who can reach Lantern can browse the shared library while it is on. Do not expose it to the internet or forward router ports to it. Original files stay unchanged.

---

[Developer guide](DEVELOPMENT.md) · [Coding-agent instructions](AGENTS.md)

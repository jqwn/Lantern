# Coding-agent instructions

## Read first

- Read `README.md` for user-facing behavior and `DEVELOPMENT.md` for architecture and verification.
- Keep the README focused on using the app; keep contributor details in DEVELOPMENT.md and operational agent rules here.

## Change scope and safety

- Prefer small fixes supported by a concrete failure or regression test. Ask before broad refactors or changing product behavior.
- Never alter original videos or subtitle files. Generated subtitles belong in the app cache.
- Do not restart, stop, or overwrite a user's running Lantern app without permission. It may be serving a TV. Build updates to a separate path.
- Keep real media titles, personal paths, credentials, and private device identifiers out of code, fixtures, documentation, and commits. Use synthetic media or explicit caller-supplied test inputs.
- Do not add cloud uploads, telemetry, new exposed APIs, or network exposure beyond the selected LAN interface without explicit approval.

## Architecture boundaries

- Keep LanternCore independent of AppKit, SwiftUI, and subprocesses so it remains reusable by a future iOS target. Do not claim iOS compatibility is verified without an iOS SDK build.
- Keep FFmpeg/ffprobe integration and Mac-specific UI/lifecycle code in LanternMac.
- Preserve indexed-file isolation, HTTP byte ranges, SOAP/XML validity, bounded network responses, and Samsung subtitle metadata when modifying the server.

## Verification

- Run `sh test.sh` for Swift tests and isolated HTTP/SSDP integration checks. The integration script uses an active IPv4 address on `en0` and briefly advertises a temporary server; it must not stop existing servers.
- Build without touching the running app with `sh build-app.sh "$PWD/dist/next/Lantern.app"`.
- Verify app bundles with `codesign --verify --deep --strict dist/next/Lantern.app` and `plutil -lint dist/next/Lantern.app/Contents/Info.plist`.
- Use synthetic fixtures for media-tool checks. Never modify a user's file or timestamps to exercise a test.
- Report build/test limitations and distinguish automated protocol checks from physical-TV or GUI verification. Do not automate the GUI unless the user requests it.

## Version control and publication

- Check for `.jj` before VCS commands. Use Jujutsu for local operations in a jj-managed checkout; otherwise use the repository's existing VCS.
- Do not commit or push unless explicitly requested. Preserve unrelated user changes.
- Keep `.build/`, `dist/`, caches, logs, and local media untracked. The source icon in `Resources/Lantern.png` is intentional; preserve its provenance.
- Before public publication, audit both tracked contents and the author/committer metadata in the history being pushed. Prefer the contributor's verified GitHub noreply address when avoiding personal-email disclosure.

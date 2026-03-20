# MacCleaner

`MacCleaner` is an opinionated macOS cleanup tool for personal use.

It focuses on reclaimable user-space clutter that tends to grow on a developer machine: caches, logs, Xcode leftovers, simulator data, Finder device backups, and stale build artifacts under `~/Desktop`.

The project includes:

- a Swift CLI for scanning and cleanup
- a simple SwiftUI macOS app
- a packaging script that builds `.app`, `.zip`, `.pkg`, and `.dmg` artifacts

## What It Cleans

`MacCleaner` targets these categories:

- `~/Library/Caches`
- `~/Library/Logs`
- `~/Library/Developer/Xcode/DerivedData`
- `~/Library/Developer/Xcode/iOS DeviceSupport`
- `~/Library/Developer/CoreSimulator/Caches`
- `~/Library/Developer/CoreSimulator/Devices/*/data` via `simctl erase`
- `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` (requires Full Disk Access)
- stale dev build caches under `~/Desktop` such as `target`, `.svelte-kit`, `.next`, `.nuxt`, `dist`, and `build` that have not been touched for 30+ days
- `~/Library/Application Support/MobileSync/Backup` as itemized Finder backups in the app (requires Full Disk Access)
- `~/.Trash`

## Privacy

This repository is intended to stay safe to publish:

- generated build output is excluded from git
- packaging artifacts in `dist/` are excluded from git
- the code and README avoid machine-specific absolute user paths
- Finder backups are only scanned locally on your Mac and are not copied into the repository

If you customize cleanup rules for your own folders, review those changes before pushing them to GitHub.

## Build

```bash
swift build
```

Debug binaries:

```bash
.build/debug/MacCleaner
.build/debug/MacCleanerUI
```

## Run

CLI:

```bash
swift run MacCleaner
swift run MacCleaner list
swift run MacCleaner scan desktop-dev-caches
swift run MacCleaner clean simulator-devices --force
```

App:

```bash
swift run MacCleanerUI
```

The app can:

- scan supported cleanup categories
- show reclaimable space by category
- clean selected categories
- show Finder backups individually and delete only the ones you choose
- show stale Desktop dev caches that match the 30-day rule

## Full Disk Access

Some categories are protected by macOS privacy controls:

- `mail-downloads`
- `mobile-backups`

If those scans fail with permission warnings, grant Full Disk Access to the app or to the terminal app you are using.

## Packaging

Build a universal app bundle and distributable archives:

```bash
./scripts/package_release.sh
```

Artifacts are written to:

```bash
dist/MacCleaner.app
dist/MacCleaner.zip
dist/MacCleaner.pkg
dist/MacCleaner.dmg
```

Override bundle metadata when needed:

```bash
BUNDLE_ID="com.yourcompany.MacCleaner" VERSION="1.0.0" BUILD_NUMBER="1" ./scripts/package_release.sh
```

To sign distributables:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name" \
INSTALLER_SIGN_IDENTITY="Developer ID Installer: Your Name" \
./scripts/package_release.sh
```

By default the packaging script uses ad-hoc signing. That is fine for local testing, but Gatekeeper will reject those artifacts on another Mac unless the user manually bypasses the warning. For normal distribution, use Developer ID signing and notarize the app or installer.

## Safety Notes

- Cleanup is opt-in. The default action is `scan`, not `clean`.
- Root directories are preserved where possible; cleanup usually removes contents, not the container directory itself.
- `Simulator Devices` resets simulator app data while keeping simulator definitions.
- Finder backups are itemized in the app instead of being deleted wholesale.
- `Old Dev Caches (Desktop)` only targets stale build artifacts and skips package payloads inside `node_modules` except `node_modules/.cache`.
- Cleaning build artifacts is safe, but the next build of those projects will be slower.
- Estimated reclaimed size is based on the pre-clean scan.

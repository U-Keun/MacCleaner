# MacCleaner

`MacCleaner` includes both a native Swift command-line tool and a very simple macOS SwiftUI app for reclaiming space from safe-to-delete user data.

It intentionally avoids system-critical locations and focuses on user-owned cache and developer artifacts:

- `~/Library/Caches`
- `~/Library/Logs`
- `~/Library/Developer/Xcode/DerivedData`
- `~/Library/Developer/Xcode/iOS DeviceSupport`
- `~/Library/Developer/CoreSimulator/Caches`
- `~/Library/Developer/CoreSimulator/Devices/*/data` via `simctl erase`
- `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` (requires Full Disk Access)
- `~/Desktop` old dev build caches such as `target`, `.svelte-kit`, `.next`, `.nuxt`, `dist`, and `build` that have been stale for 30+ days
- `~/Library/Application Support/MobileSync/Backup` (requires Full Disk Access, individual backup deletion in the UI)
- `~/.Trash`

## Build

```bash
swift build
```

The executables will be available at:

```bash
.build/debug/MacCleaner
.build/debug/MacCleanerUI
```

## Run The App

Launch the simple macOS UI:

```bash
swift run MacCleanerUI
```

The UI can:

- scan supported cleanup categories
- show estimated reclaimable space per category
- let you select categories with checkboxes
- clean only the selected categories
- highlight categories that require Full Disk Access or need itemized cleanup
- show Finder device backups individually so you can delete only the backups you choose

## Package For Another Mac

Create a universal app bundle plus `zip`, `pkg`, and `dmg` artifacts:

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

You can override metadata at packaging time:

```bash
BUNDLE_ID="com.yourcompany.MacCleaner" VERSION="1.0.0" BUILD_NUMBER="1" ./scripts/package_release.sh
```

To sign the distributables:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name" \
INSTALLER_SIGN_IDENTITY="Developer ID Installer: Your Name" \
./scripts/package_release.sh
```

By default the script uses ad-hoc signing. Gatekeeper will reject those artifacts on another Mac unless the user manually bypasses the warning. For normal distribution, use Developer ID signing and notarize the result.

## Usage

Scan everything:

```bash
swift run MacCleaner
```

Scan only specific categories:

```bash
swift run MacCleaner scan caches logs
```

Scan protected categories:

```bash
swift run MacCleaner scan mail-downloads mobile-backups
```

Scan stale Desktop dev caches:

```bash
swift run MacCleaner scan desktop-dev-caches
```

Get JSON output:

```bash
swift run MacCleaner scan all --json
```

Preview and clean everything:

```bash
swift run MacCleaner clean all
```

Skip the confirmation prompt:

```bash
swift run MacCleaner clean simulator-devices xcode-derived-data --force
```

List supported categories:

```bash
swift run MacCleaner list
```

## Safety notes

- The tool only deletes the contents inside the supported directories, not the root directories themselves.
- `Simulator Devices` uses `xcrun simctl erase` to reset simulator app data while keeping the simulator definitions.
- `Mail Downloads` and `Device Backups` usually require Full Disk Access to inspect.
- `Device Backups` stays itemized. The app lists backup folders individually instead of deleting the entire backup root in one click.
- `Old Dev Caches (Desktop)` only targets stale build artifacts older than 30 days and skips `node_modules` package payloads. Cleaning them is safe, but the next build of those projects will be slower.
- Cleanup is opt-in. The default action is `scan`, not `clean`.
- The estimated reclaimed size is based on the pre-clean scan.
- Some directories can still fail with permission errors depending on local macOS privacy settings.

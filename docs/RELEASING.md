# Releasing

This project is intended to be distributed outside the Mac App Store.

## Recommended release path

1. Build the app bundle locally.
2. Sign it with `Developer ID Application`.
3. Package it as a `.dmg`.
4. Notarize it with Apple.
5. Generate the Sparkle appcast entry for the release.
6. Publish the notarized `.dmg` in GitHub Releases.
7. Commit and publish the updated appcast and release notes.

For normal users, that is the cleanest and most trusted distribution path.

## Planned public release download

Once the repository is public, the release page should expose:

- `LofreeDongleBattery-<version>.dmg`

Placeholder release URL:

`https://github.com/DigitalEdens/lofree-mac-2-4ghz-dongle-battery/releases/latest`

## Local build

```bash
./scripts/build_app.sh
```

Output:

- `dist/LofreeDongleBattery.app`

## Signed build

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh
```

## Create the DMG

```bash
./scripts/create_dmg.sh
```

Output:

- `dist/LofreeDongleBattery-<version>.dmg`

## Sparkle setup

The build script will download the official Sparkle distribution automatically if it is not already available locally.

You can also fetch it explicitly:

```bash
./scripts/setup_sparkle.sh
```

The app uses this GitHub-hosted update feed:

`https://raw.githubusercontent.com/DigitalEdens/lofree-mac-2-4ghz-dongle-battery/main/docs/appcast.xml`

## Important

Do **not** ship public releases signed with `Apple Development`.

For public distribution, use:

- `Developer ID Application`

That is the proper identity type for outside-App-Store macOS distribution.

If you sign releases under an **individual** Apple Developer membership, macOS security prompts will show your personal legal developer name. That is Apple platform behavior, not something controlled by this repository.

## Notarization

After signing with `Developer ID Application`, notarize the `.dmg` with Apple before publishing it.

Store a local `notarytool` keychain profile first:

```bash
xcrun notarytool store-credentials "lofree-notary"
```

Then run:

```bash
./scripts/notarize_dmg.sh
```

That script submits the versioned DMG in `dist/` and staples the notarization ticket when it completes.

## Generate the appcast entry

After the DMG has been signed and notarized, generate the updated Sparkle feed:

```bash
./scripts/generate_appcast.sh v1.0.0
```

That script updates:

- `docs/appcast.xml`
- `docs/release-notes/1.0.0.md`

Use the same GitHub release tag in the command that you plan to publish, because the appcast points to:

`https://github.com/DigitalEdens/lofree-mac-2-4ghz-dongle-battery/releases/download/<tag>/LofreeDongleBattery-<version>.dmg`

## Public repo hygiene

Do not publish:

- local archive folders
- reverse-engineering scratch files
- unsigned build products
- personal signing metadata copied from a local build

This repository's `.gitignore` is set up to keep those artifacts out of version control by default.

## Updates

This repository is prepared for Sparkle-based in-app updates using:

- GitHub Releases for release archives
- the public `docs/appcast.xml` feed
- EdDSA signatures managed by Sparkle

The app is configured for manual update checks only, so users will only see update prompts after clicking `Check for Updates…`.

## DMG naming

For release clarity and simpler publishing, the scripts generate only:

- `LofreeDongleBattery-<version>.dmg`

That same versioned file is used both for GitHub Releases and for Sparkle updates.

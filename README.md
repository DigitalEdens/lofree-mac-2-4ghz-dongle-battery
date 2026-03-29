# Lofree 2.4 GHz Dongle Battery

A small macOS menu bar app that shows the live battery percentage of a compatible Lofree keyboard over the official `2.4 GHz` USB receiver or over Bluetooth.

## Unofficial project

This is an independent, unofficial utility for compatible Lofree keyboards.

It is not affiliated with, endorsed by, or published by Lofree.

`Lofree` is mentioned only to describe hardware compatibility.

## In plain English

This app talks to the Lofree USB dongle when you are using `2.4 GHz`, or reads the standard battery service when the keyboard is already connected over Bluetooth, and shows that battery information in the macOS menu bar.

## Download

[Download the latest release](https://github.com/DigitalEdens/lofree-mac-2-4ghz-dongle-battery/releases/latest)

Download the versioned DMG from the latest GitHub release, for example `LofreeDongleBattery-1.0.4.dmg`.

## What the app shows

- live battery percentage
- charging state
- battery voltage reported by the device on `2.4 GHz`
- current connection type
- last updated time
- a manual check mode for `Auto`, `Bluetooth only`, or `2.4 GHz only`

## Tested keyboards

The following keyboard has been tested with this app:

- [LOFREE Flow Lite100 Mechanical Keyboard (100 keys)](https://www.lofree.co/products/flow-lite100-mechanical-keyboard)

Other Lofree models or receivers may behave differently and are not guaranteed to work yet.

If you test it with another keyboard model, please comment under the Reddit post with your model and results so we can collaboratively test support and improve compatibility for other Lofree boards.

## Why macOS asks for Input Monitoring

macOS protects low-level access to keyboard-like HID devices behind **Input Monitoring**.

This app needs that permission because the Lofree receiver presents itself in a protected HID class. Without it, the app cannot talk to the dongle and the live battery percentage will not appear.

The permission is used only so the app can ask the dongle for battery data over `2.4 GHz`.

It does **not** capture typed text, record keystrokes, or send your keyboard activity anywhere.

Read the full explanation here:

- [How it works](./docs/HOW_IT_WORKS.md)
- [Permissions and privacy](./docs/PERMISSIONS_AND_PRIVACY.md)

## Install

### When public releases are available

1. Download the versioned DMG from GitHub Releases, for example `LofreeDongleBattery-1.0.4.dmg`.
2. Open the DMG.
3. Drag `LofreeDongleBattery.app` into `Applications`.
4. Open the app from `Applications`.
5. When macOS requests Input Monitoring access, enable `LofreeDongleBattery.app`.

## First run note

On first launch, it can take up to about a minute for the battery percentage to appear.

That initial delay is expected while macOS finishes the permission flow and the app waits for the first live battery response from the dongle.

### Build from source

```bash
./scripts/build_app.sh
```

That produces:

- `dist/LofreeDongleBattery.app`

To create the release DMG:

```bash
./scripts/create_dmg.sh
```

That produces:

- `dist/LofreeDongleBattery-<version>.dmg`

## How it works

The app checks battery data in two ways:

1. Over `2.4 GHz`, it opens the Lofree dongle over HID and requests a fresh battery reading directly.
2. Over Bluetooth, it reads the keyboard's standard Bluetooth battery service if the keyboard is already connected to the Mac.

## Trust and transparency

- The source code is public so anyone can inspect how the permission is used.
- The app does not include analytics or telemetry.
- The only network action in the app is opening the optional support link in your browser if you click `Buy me a coffee`.
- Official release builds will be signed and notarized outside the Mac App Store.

## Official builds

Official builds are the signed releases published from this repository.

Forks and unofficial builds may remove or change:

- permission messaging
- the support link
- update behavior
- release packaging

## Updates

The app is set up to use Sparkle for official in-app updates.

Official updates are intended to be delivered through:

- GitHub Releases for the signed and notarized versioned DMG files
- a GitHub-hosted appcast feed for Sparkle

This app is configured for manual update checks only. It will only look for updates when you click `Check for Updates…` in the menu.

## Future plans

- broader Lofree keyboard models compatibility 
- You can request features here on the Reddit thread https://www.reddit.com/r/Lofree/comments/1s4e05k/
## Support

- [Buy me a coffee](https://digitaledens.com/buy-me-a-coffee/)

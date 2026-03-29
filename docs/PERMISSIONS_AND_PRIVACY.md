# Permissions and Privacy

## Why macOS asks for Input Monitoring

This app talks directly to the Lofree `2.4 GHz` USB receiver using low-level HID access. On macOS, keyboard-like HID access is protected by **Input Monitoring**, even when an app is not trying to read what you type.

Because the Lofree receiver appears in that protected class, macOS requires Input Monitoring before the app can open the device.

Without this permission, the app cannot talk to the receiver and the battery percentage will not appear.

## Why it is safe in this app

The permission is needed only so the app can talk to the receiver and ask for battery information over `2.4 GHz`.

This app does not use Input Monitoring to inspect what you type, and it does not send your keyboard data anywhere.

## What the permission is used for

The app uses Input Monitoring only to:

- open the Lofree receiver
- send the battery request over `2.4 GHz`
- receive the battery response

## What the app does not do

This app does **not**:

- capture typed text
- record keystrokes
- upload keyboard data
- send analytics or telemetry

The only browser/network action in the app is opening the optional support page when `Buy me a coffee` is clicked.

As the developer, I do **not** have access to:

- your keystrokes
- your local battery readings
- your machine

## What data the app shows

The app displays device-reported battery information:

- battery percentage
- charging status
- voltage on `2.4 GHz`
- Bluetooth battery percentage when the keyboard is already connected over Bluetooth

## First run behavior

On first launch, it can take up to about a minute for the first live battery percentage to appear.

That delay is expected while macOS finishes the permission flow, the app opens the receiver, and the first battery reply comes back from the dongle.

## Why the source code is public

The source is public so anyone can inspect how the permission is used.

The main runtime file is:

- `Sources/LofreeDongleBatteryMenu/main.swift`

## Your control

You can revoke the permission at any time in:

`System Settings > Privacy & Security > Input Monitoring`

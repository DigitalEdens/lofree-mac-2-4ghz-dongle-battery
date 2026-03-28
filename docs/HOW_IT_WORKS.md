# How It Works

## Short version

The app reads battery data directly from the Lofree `2.4 GHz` USB dongle and shows that live percentage in the macOS menu bar.

## Step by step

1. You launch `LofreeDongleBattery.app`
2. The app starts a bundled helper called `Lofree Dongle Battery Access`
3. The helper opens the Lofree USB receiver over HID
4. The helper sends the battery request to the dongle
5. The keyboard replies with battery data through the dongle
6. The helper returns that result to the menu bar app
7. The menu bar app shows the battery percentage

On the first launch, this can take up to about a minute while macOS finishes the permission flow and the app waits for the first live battery reply from the dongle.

## Why a helper is used

The helper exists so the sensitive HID access is isolated to a small, named component.

That makes the permission model easier to understand in macOS and keeps the menu bar app itself simpler.

## What battery data is used

The helper reads the data reported by the device itself:

- battery percentage
- charging flag
- voltage

The app displays the live battery percentage in the menu bar and shows the additional details in the dropdown menu.

## Why Input Monitoring is needed

macOS treats this receiver as a protected keyboard-like HID device.

Because of that, the helper must be allowed under:

`System Settings > Privacy & Security > Input Monitoring`

Without that permission, the helper cannot open the receiver and the battery percentage will not appear.

That permission allows the helper to open the receiver. It does not give the developer remote access to your keyboard or your computer.

# How It Works

## Short version

The app reads battery data from the Lofree `2.4 GHz` USB dongle or from an already-connected Bluetooth keyboard session and shows that live percentage in the macOS menu bar.

## Step by step

1. You launch `LofreeDongleBattery.app`
2. If the keyboard is on `2.4 GHz`, the app opens the Lofree USB receiver over HID
3. The app sends the battery request to the dongle
4. The keyboard replies with battery data through the dongle
5. If the keyboard is already connected over Bluetooth instead, the app reads the standard Bluetooth battery service
6. The menu bar app shows the battery percentage and connection details

On the first launch, this can take up to about a minute while macOS finishes the permission flow and the app waits for the first live battery reply from the dongle.

## What battery data is used

On `2.4 GHz`, the app reads the data reported by the device itself:

- battery percentage
- charging flag
- voltage

On Bluetooth, the app reads the standard battery percentage only, so voltage is shown as unavailable on Bluetooth.

The app displays the live battery percentage in the menu bar and shows the additional details in the dropdown menu.

## Why Input Monitoring is needed

macOS treats this receiver as a protected keyboard-like HID device.

Because of that, the app must be allowed under:

`System Settings > Privacy & Security > Input Monitoring`

Without that permission, the app cannot open the receiver and the `2.4 GHz` battery percentage will not appear.

That permission allows the app to open the receiver. It does not give the developer remote access to your keyboard or your computer.

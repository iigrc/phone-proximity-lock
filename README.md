# Phone Proximity Lock

A macOS menu bar app that locks your Mac when a selected paired Bluetooth device disconnects. Automatic unlocking on reconnection is optional and disabled by default.

## Requirements

- macOS 13 or later
- Bluetooth enabled on the Mac and selected device
- Xcode Command Line Tools to build from source

The app builds for Apple silicon and Intel. It has been tried on one Apple silicon Mac; Intel and other macOS versions still need testing.

## Build

```sh
bash build-shareable.sh
```

This builds a universal executable, creates a locally signed app, runs the built-in self-tests, and packages version 0.2.1 under `dist/`.

The app is locally signed, not Developer ID signed or notarized. Follow your organization's approval process if macOS blocks it. A wider release requires Developer ID signing and notarization.

## Use

1. Move the built `Phone Proximity Lock.app` into Applications and open it.
2. Open **Settings & devices** from the menu bar.
3. Choose a paired device and click **Use selected device**, or pair a new device first.
4. Test the device's disconnect and reconnect behavior before relying on it.

By default, locking starts after 20 seconds of disconnection. Bluetooth range can extend beyond a room, and some devices do not maintain a usable connection. Monitoring resumes when the Mac wakes from sleep.

Optional automatic unlocking requires Accessibility permission and your Mac login password, verified locally and stored in your login Keychain. It is limited to locks initiated by this app; manual locks and initial login remain manual. Changing the selected device turns automatic unlocking off again.

Settings and activity logs live in `~/Library/Application Support/Phone Proximity Lock/`. They are not included in this repository. The app can import settings from an older local installation; automatic unlocking is paused during migration.

See [SHARING.txt](SHARING.txt) for setup, upgrade, and uninstall instructions.

## Verification

After building, run the checks without accessing the Keychain or locking the screen:

```sh
'dist/Phone-Proximity-Lock-0.2.1/Phone Proximity Lock.app/Contents/MacOS/PhoneLock' --self-test
```

These checks cover configuration and unlock timing logic. They do not replace testing Bluetooth disconnect/reconnect, sleep/wake, and actual locking on the target Mac.

## Source files

- `PhoneLock.swift`: app entry point, menu bar controls, and monitoring
- `BluetoothConnectionWorker.swift`: authenticated Bluetooth worker process
- `DeviceSettings.swift`: device selection, settings, and login startup
- `UnlockSupport.swift`: unlock gating, Keychain storage, and secure login interaction
- `Distribution-Info.plist`: app metadata
- `build-shareable.sh`: universal app build and packaging

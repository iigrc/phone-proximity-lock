#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"
release_dir="$project_dir/dist/Phone-Proximity-Lock-0.2.1"
bundle_path="$release_dir/Phone Proximity Lock.app"
mkdir -p "$bundle_path/Contents/MacOS" "$project_dir/build/module-cache"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
frameworks=(AppKit IOBluetooth IOBluetoothUI CoreGraphics Security OpenDirectory IOKit ApplicationServices LocalAuthentication)
framework_args=()
for framework in "${frameworks[@]}"; do framework_args+=(-framework "$framework"); done
for architecture in arm64 x86_64; do
  xcrun swiftc -O -module-name PhoneProximityLock -sdk "$sdk_path" \
    -target "$architecture-apple-macos13.0" -module-cache-path build/module-cache \
    "${framework_args[@]}" PhoneLock.swift UnlockSupport.swift DeviceSettings.swift BluetoothConnectionWorker.swift \
    -o "build/PhoneLock-$architecture"
done
xcrun lipo -create build/PhoneLock-arm64 build/PhoneLock-x86_64 -output "$bundle_path/Contents/MacOS/PhoneLock"
cp Distribution-Info.plist "$bundle_path/Contents/Info.plist"
cp SHARING.txt "$release_dir/Read me first.txt"
codesign --force --sign - --options runtime "$bundle_path"
codesign --verify --strict "$bundle_path"
"$bundle_path/Contents/MacOS/PhoneLock" --self-test
ditto --norsrc --noextattr -c -k --keepParent "$release_dir" "$project_dir/dist/Phone-Proximity-Lock-0.2.1.zip"
printf '%s\n' "$project_dir/dist/Phone-Proximity-Lock-0.2.1.zip"

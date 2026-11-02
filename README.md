# Earmark

Menu bar app for macOS that sends each app's audio to the output device you pick, at its own volume.
For example: a browser on the built-in speakers at 60%, Discord on AirPods at 100%.

- Per-app output device and volume, remembered per app and re-applied automatically
- Master volume and mute for each output device
- No virtual audio driver: uses Core Audio process taps

## Requirements

macOS 26, Xcode command line tools (Swift 6).

## Build

```sh
./Scripts/make-app.sh
open build/Earmark.app
```

The script signs with your first "Apple Development" identity if you have one, so the
"System Audio Recording" permission survives rebuilds; otherwise it signs ad-hoc and macOS asks again after each build.

Grant "System Audio Recording" when asked the first time you route an app.

## How it works

For each app you change, Earmark creates a muted process tap on the app's processes (helpers included) and a private
aggregate device made of the tap and the target output device. An IOProc copies the tapped audio to the device at the
app's volume. Apps left on the system default at 100% are not touched.

## Test

```sh
swift test
```

# iOS sideload from Linux

Build an unsigned `.ipa` of OpenNutriTracker on a GitHub Actions macOS runner, then sign and install it onto a tethered iPhone from Linux using AltServer-Linux. No Mac, no jailbreak, no paid Apple Developer account.

## When to use this

For iOS-specific work where you need a real device and can't borrow a Mac — accessibility bugs like #107, layout regressions that don't reproduce on Android, anything where the test plan ends with "screenshot the iPhone." The build is unsigned and gets re-signed locally with a free personal Apple ID, so the app is valid for **seven days** before AltServer needs to refresh it. Fine for short iteration loops, awkward for long-running test sessions.

## Per-test workflow

1. Push the branch you want to test.
2. Trigger the build:
   ```sh
   gh workflow run ios_sideload.yml \
     -R simonoppowa/OpenNutriTracker \
     -f ref=feature/your-branch
   ```
   Wait ~10–15 minutes for the macOS runner. The default ref is `develop` if you omit `-f ref=...`.
3. Download the artefact:
   ```sh
   gh run download -R simonoppowa/OpenNutriTracker \
     -n opennutritracker-ios-sideload \
     -D /tmp/ont-ipa
   ```
   You'll get `OpenNutriTracker-sideload.ipa` in `/tmp/ont-ipa/`.
4. Plug the iPhone in if it isn't already. Unlock it. Trust the computer if iOS prompts.
5. Run AltServer-Linux pointing at the IPA and your Apple ID:
   ```sh
   ./AltServer -u /tmp/ont-ipa/OpenNutriTracker-sideload.ipa \
     -a your-apple-id@example.com \
     -p '<app-specific-password-if-2FA>'
   ```
6. The signed app lands on the phone. Open it, run whatever test you came for, screenshot, capture logs.

The signed app expires after seven days. To refresh, re-run AltServer with the same IPA — no need to rebuild from CI unless the source changed.

## One-time setup

### Apple ID

Any free Apple ID works. If yours has two-factor authentication enabled, generate an app-specific password at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords and use that as the `-p` value.

Free personal teams have a few documented limits:

- Up to **three sideloaded apps** at once per Apple ID (the OS counts apps installed via free-team signing).
- Each install is valid for **seven days**, then the app refuses to launch until re-signed.
- Bundle identifiers registered to a paid team are off-limits, which is why the workflow patches `com.opennutritracker.ont.opennutritracker` to `com.opennutritracker.ont.opennutritracker.sideload` before building. The sideload app is a separate iOS application from the App Store build — separate Hive boxes, separate notifications, no shared data. That's intentional and makes test isolation easier.

### Linux machine

Install libimobiledevice — the underlying USB toolchain AltServer uses:

```sh
sudo apt install libimobiledevice-utils usbmuxd ideviceinstaller
```

Verify the iPhone shows up over USB:

```sh
idevice_id -l
# Should print one or more 40-character device IDs.
```

If the iPhone is plugged in but `idevice_id` returns nothing, unplug, restart `usbmuxd`, plug back in:

```sh
sudo systemctl restart usbmuxd
```

Trust the computer on the iPhone when prompted (Settings → General → VPN & Device Management afterwards if you missed the dialog).

### AltServer-Linux

Grab the latest release from https://github.com/NyaMisty/AltServer-Linux. The binary doesn't need installing — drop it in `~/bin/` or wherever and `chmod +x AltServer`.

Sanity check before the first run:

```sh
./AltServer --help
```

## Troubleshooting

**`pod install` fails on the runner.** Usually means `Podfile.lock` has drifted from `pubspec.yaml`. Run the same script locally on a Mac if you have one, or open a PR against `develop` first — the regular `ios-build` job has auto-commit for the lockfile and will refresh it for you.

**AltServer prints `Could not find a team`.** Your Apple ID hasn't been used for development before. Go to Settings → Privacy & Security on the iPhone, scroll to Developer Mode if running iOS 16+, and toggle it on. Restart the phone, accept the developer mode prompt, retry AltServer.

**AltServer prints `bundle id already in use`.** The default sideload id is `com.opennutritracker.ont.opennutritracker.sideload`. If you've sideloaded the same id with a different Apple ID before, that one needs to be cleared first — Settings → General → VPN & Device Management → tap your Apple ID profile → Remove App.

**The app launches but immediately closes after seven days.** That's the free-team expiry. Re-run AltServer with the same IPA to re-sign.

**`flutter build ios --no-codesign` succeeds in CI but the Runner.app directory is missing.** Look at the macOS runner logs for an Xcode codesign warning — sometimes Xcode emits the .app to a different path when the signing identity isn't set. The workflow's "Wrap .app into unsigned .ipa" step will fail loudly if that happens, with the path it expected.

## Why not TestFlight

If Simon's around and able to push a TestFlight build, that's still the fastest path for one-off testing — no AltServer dance, no seven-day timer, 90 days of validity per build. This workflow exists for the in-between case where you need to iterate on iOS-specific code on your own cadence without blocking on someone else's calendar.

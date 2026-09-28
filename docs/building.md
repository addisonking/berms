# building for personal devices

how to get berms (iphone + apple watch) and bermsstudio (macos) onto your own hardware from a mac with xcode. no app store, no testflight, no notarization.

you sign these builds with your own apple account. the project ships pointing at my team and `com.addis.berms` bundle ids, so the first step is swapping both for yours (next section). after that an agent can do the builds and installs; the device-side steps (trusting the certificate, developer mode, permission prompts) are for a human.

## what you need

- a mac with the release version of xcode 26 or newer. betas reject the project's legacy watchkit2 extension target.
- an iphone on ios 26+, and for heart rate and live stats a paired apple watch on watchos 26+.
- an apple id added in xcode under settings → accounts. a free account works, but its builds stop launching after 7 days; a paid membership lasts a year.
- developer mode enabled on the iphone and the watch.
- for bermsstudio: macos 26+ and `ffmpeg`/`ffprobe` on the path (`brew install ffmpeg`).

## change the team and bundle ids first (human, one time)

the repo ships with `DEVELOPMENT_TEAM = SAQUMQUCR6` and bundle ids under `com.addis.berms`. those are mine, and nothing will sign until you replace them with your own.

1. open `Berms.xcodeproj`, select the project, then each target (berms, bermswatch, bermswatchextension, bermsliveactivity, bermsstudio), and pick your team under signing & capabilities.
2. change the bundle ids to your own prefix. keep the nesting apple expects:
   - `Berms.app` → `com.you.berms`
   - `BermsWatch.app` → `com.you.berms.watchkitapp`
   - `BermsWatchExtension` → `com.you.berms.watchkitapp.watchkitextension`
   - `BermsLiveActivity` → `com.you.berms.liveactivity`
   - `BermsTests` → `com.you.berms.tests`
   - `BermsStudio` (macos) can be anything, like `com.you.bermsstudio`
3. leave signing on automatic. xcode registers the app ids and devices for you.

healthkit is in `Berms.entitlements` and `BermsWatchExtension.entitlements`. it needs an explicit app id and a profile that carries the entitlement, and some free personal teams can't get one issued. if xcode fails at signing with a healthkit error, that's an account limitation rather than a code problem, and a paid apple developer program membership is the fix. without healthkit the watch app can't run its workout session or read heart rate.

## for agents (once signing works)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# find the device
xcrun devicectl list devices

# build for the phone
xcodebuild -project Berms.xcodeproj -scheme Berms \
  -destination 'id=<device-id>' \
  -derivedDataPath /tmp/berms-device-build \
  -allowProvisioningUpdates build

# install and launch (use your bundle id if you changed it)
xcrun devicectl device install app --device <device-id> \
  /tmp/berms-device-build/Build/Products/Debug-iphoneos/Berms.app
xcrun devicectl device process launch --device <device-id> com.addis.berms
```

- use the stable toolchain at `/Applications/Xcode.app`. a beta toolchain can't build the watch extension, and the shell needs `DEVELOPER_DIR` when it isn't the selected xcode.
- there's no separate watch build: the watch app is embedded in the phone app (embed watch content). xcode pushes it to the paired watch when you run the phone app, so if the watch app is missing after a command-line-only install, run once from xcode.
- for a simulator instead of a device, use `-destination 'platform=iOS Simulator,name=iPhone 17 Pro'` and `xcrun simctl install` / `launch`. the simulator has no barometer and no heart rate, so live tracking stays on "waiting for gps" and the watch stats stay blank; use hardware for that.
- studio:

```sh
xcodebuild -project Berms.xcodeproj -scheme BermsStudio \
  -configuration Release -derivedDataPath /tmp/berms-studio-build build
```

the app lands in `/tmp/berms-studio-build/Build/Products/Release/BermsStudio.app`; drag it to `/Applications` when you're happy with it.

- an agent can't do the human steps below: tapping trust on a dialog, flipping developer mode, or allowing a permission sheet.

## for humans (device side)

1. install once from xcode itself (scheme `Berms`, your iphone as the destination, ⌘R). that's what registers the device and creates the profiles; the command-line flow works after that.
2. trust the developer app on the phone: settings → general → vpn & device management → developer app → trust.
3. turn on developer mode. iphone: settings → privacy & security → developer mode, then restart. watch: settings → privacy & security → developer mode, and leave it on the charger for the first install.
4. the first launch on the watch asks for health access (workout + heart rate). allow it or the bpm row stays blank.
5. the first launch on the phone asks for location and motion & fitness. pick always for location: berms only records when you tell it to, but it needs the background mode to keep tracking with the screen off.
6. start a ride on the phone. the watch app opens itself through `startWatchApp`; if it doesn't, open berms on the watch once.
7. if you move `BermsStudio.app` to another mac, clear the quarantine bit, or allow it in system settings → privacy & security:

```sh
xattr -dr com.apple.quarantine /Applications/BermsStudio.app
```

## notes

- free apple id builds expire after 7 days. rebuild and reinstall to refresh them.
- installing a new build over the same bundle id keeps your rides and archives. deleting the app deletes them, so export days first if you care.
- every build stamps the git commit and dirty state into the app, and about berms beta shows it. build from a clone or worktree and expect "local changes" when your tree isn't clean.
- checks: `./scripts/test.sh` (simulator), `./scripts/lint.sh`, `./scripts/format.sh`.

## troubleshooting

- "personal team doesn't support healthkit" or a healthkit profile error → account limitation, see above.
- device missing from `devicectl list devices` → unlock it, trust the computer, use the same network or a cable, and make sure developer mode is on.
- "untrusted developer" when launching → do the trust step.
- watch app never appears → developer mode on the watch, unlocked and charging, then run once from xcode.
- signing fails after changing bundle ids → check the nesting still matches and clear old profiles under xcode settings → accounts.
- xcode won't run a build at all → `sudo xcodebuild -license accept`.

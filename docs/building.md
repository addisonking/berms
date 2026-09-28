# building

how to get berms (iphone + apple watch) and bermsstudio (macos) onto your own hardware from a mac with xcode. no app store, no testflight, no notarization.

you sign these builds with your own apple account. the checkout ships pointing at my team and `com.addis.berms` bundle ids, so the first thing that has to happen is swapping both for yours: `scripts/configure-signing.py` does that swap in one command. an agent can drive everything from a blank mac (block below); the device-side steps (trusting the certificate, developer mode, permission prompts) are for a human.

## what you need

- a mac with the release version of xcode 26 or newer. betas reject the project's legacy watchkit2 extension target.
- an apple id added in xcode under settings → accounts. the agent can't do this part. a free account works, but its builds stop launching after 7 days; a paid membership lasts a year.
- an iphone on ios 26+ with developer mode on (settings → privacy & security → developer mode, then restart).
- for heart rate and live stats: a paired apple watch on watchos 26+ with developer mode on. healthkit needs a profile that carries the entitlement, and free personal teams often can't get one issued; if xcode fails with a healthkit signing error, that's an account limitation, not a code problem, and a paid apple developer program membership is the fix. the phone app works without the watch.
- for bermsstudio: macos 26+ and `ffmpeg`/`ffprobe` on the path (`brew install ffmpeg`).

## start from zero with an agent

paste this into claude code, codex, or any agent with shell access. it doesn't matter where the agent starts or whether the repo is there yet; it asks you for the values it can't find on its own, and finds or clones the checkout:

````text
Set up the berms iPhone app on my phone, and the Apple Watch app if I have a watch. Work through the steps in order and stop whenever you need something from me.

Ask me for all of these in one message first, and wait for my answers before starting:
- my Apple team id (10 letters or digits). Detect it if you can: `security find-identity -v -p codesigning` shows it as "(TEAMID)" when an Apple Development certificate exists. Otherwise ask me to sign in to Xcode under Settings → Accounts, or find it at developer.apple.com → account → membership.
- the bundle id to use for the app, e.g. com.myname.berms. I need to own it and it can't collide with an app I already have. The other targets' ids are derived from it.
- do I have an Apple Watch paired, and do I want the macOS BermsStudio app built too.
- where the repo should live if you have to clone it. If you're already inside a berms checkout, use it; otherwise clone to `~/berms` unless I say otherwise.

Then:
1. Confirm the release Xcode 26 or newer is at /Applications/Xcode.app. If it's missing or only a beta is installed, tell me what to install and stop. Use DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer for every xcodebuild and xcrun command.
2. Find an existing berms checkout (the current directory, or `~/berms`); if there isn't one, clone https://github.com/addisonking/berms.git to the path I gave. Work from that directory for the rest of the steps: run `python3 scripts/configure-signing.py <team-id> <bundle-id>` and show me what it changed.
3. Find my iPhone with `xcrun devicectl list devices` (ask me which one if several look plausible), then build:
   xcodebuild -project Berms.xcodeproj -scheme Berms -destination 'id=<device-id>' -derivedDataPath /tmp/berms-device-build -allowProvisioningUpdates build
4. If the build fails on signing, account, certificate, or profile errors, give me the exact Xcode steps (open Xcode, add my Apple ID under Settings → Accounts, choose my team for every target, then run once with my iPhone selected), wait for me to confirm, and retry.
5. Install and launch:
   xcrun devicectl device install app --device <device-id> /tmp/berms-device-build/Build/Products/Debug-iphoneos/Berms.app
   xcrun devicectl device process launch --device <device-id> <bundle-id>
6. Tell me the phone-side steps only I can do: trust the developer app under Settings → General → VPN & Device Management, then on first launch allow location (Always) and Motion & Fitness.
7. If I have a watch: remind me to turn on developer mode on it, keep it unlocked and on the charger for the first install, allow the Health prompts, and if the watch app never appears, run once from Xcode with the watch paired.
8. If I asked for studio: build scheme BermsStudio with configuration Release and derivedDataPath /tmp/berms-studio-build, tell me where BermsStudio.app is, and check that ffmpeg and ffprobe are installed (brew install ffmpeg if not).
9. Finish by running ./scripts/lint.sh and ./scripts/test.sh and tell me if either fails.
````

## doing it by hand

1. get your two values:
   - team id: 10 letters/digits. `security find-identity -v -p codesigning` prints it as `(TEAMID)` once you've signed in to xcode and built something; otherwise it's under membership at developer.apple.com.
   - bundle id: something you own, like `com.you.berms`. the script derives `.watchkitapp`, `.watchkitapp.watchkitextension`, `.liveactivity`, `.tests`, and `.studio` from it.
2. clone and configure. `--dry-run` first if you want to see the diff:
   ```sh
   git clone https://github.com/addisonking/berms.git
   cd berms
   python3 scripts/configure-signing.py YOURTEAMID com.you.berms --dry-run
   python3 scripts/configure-signing.py YOURTEAMID com.you.berms
   ```
   it rewrites only the team and bundle id settings, in `Berms.xcodeproj/project.pbxproj` and the two watch `Info.plist` files. `git checkout .` undoes it. if you'd rather click, select the project and each target in xcode under signing & capabilities, pick your team, and change the bundle ids to your prefix keeping apple's nesting: app, `.watchkitapp`, `.watchkitapp.watchkitextension`, `.liveactivity`, `.tests`, `.studio`.
3. build, install, and launch on the phone:
   ```sh
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcrun devicectl list devices
   xcodebuild -project Berms.xcodeproj -scheme Berms \
     -destination 'id=<device-id>' \
     -derivedDataPath /tmp/berms-device-build \
     -allowProvisioningUpdates build
   xcrun devicectl device install app --device <device-id> \
     /tmp/berms-device-build/Build/Products/Debug-iphoneos/Berms.app
   xcrun devicectl device process launch --device <device-id> com.you.berms
   ```
   the stable toolchain at `/Applications/Xcode.app` matters: a beta toolchain can't build the watch extension, and the shell needs `DEVELOPER_DIR` when that isn't the selected xcode. if signing can't register the device or create a profile from the command line, run once from xcode itself (scheme `Berms`, your iphone as the destination, ⌘R) and the command-line flow works after that.
4. there's no separate watch build: the watch app is embedded in the phone app (embed watch content), and xcode pushes it to the paired watch when you run the phone app. if the watch app is missing after a command-line-only install, run once from xcode. keep the watch unlocked and on the charger for that first install.
5. simulator instead of a device: use `-destination 'platform=iOS Simulator,name=iPhone 17 Pro'` and `xcrun simctl install` / `launch`. the simulator has no barometer and no heart rate, so live tracking stays on "waiting for gps" and the watch stats stay blank.
6. studio:
   ```sh
   xcodebuild -project Berms.xcodeproj -scheme BermsStudio \
     -configuration Release -derivedDataPath /tmp/berms-studio-build build
   ```
   the app lands in `/tmp/berms-studio-build/Build/Products/Release/BermsStudio.app`; drag it to `/Applications`. if you move it between macs, clear the quarantine bit or allow it in system settings → privacy & security:
   ```sh
   xattr -dr com.apple.quarantine /Applications/BermsStudio.app
   ```
7. first launch, device side:
   1. trust the developer app on the phone: settings → general → vpn & device management → developer app → trust.
   2. the watch wants its own developer mode: settings → privacy & security → developer mode.
   3. the phone asks for location and motion & fitness. pick always for location: berms only records when you tell it to, but it needs the background mode to keep tracking with the screen off.
   4. the watch asks for health access (workout + heart rate) on its first launch. allow it or the bpm row stays blank.
   5. start a ride on the phone. the watch app opens itself through `startWatchApp`; if it doesn't, open berms on the watch once.
8. checks: `./scripts/test.sh` (simulator), `./scripts/lint.sh`, `./scripts/format.sh`.

## notes

- free apple id builds expire after 7 days. rebuild and reinstall to refresh them.
- installing a new build over the same bundle id keeps your rides and archives. deleting the app deletes them, so export days first if you care.
- every build stamps the git commit and dirty state into the app, and about berms beta shows it. build from a git clone or worktree (not a downloaded zip) and expect "local changes" when your tree isn't clean.

## troubleshooting

- "personal team doesn't support healthkit" or a healthkit profile error → account limitation, see above.
- device missing from `devicectl list devices` → unlock it, trust the computer, use the same network or a cable, and make sure developer mode is on.
- "untrusted developer" when launching → do the trust step.
- watch app never appears → developer mode on the watch, unlocked and charging, then run once from xcode.
- signing fails after changing bundle ids → rerun `python3 scripts/configure-signing.py YOURTEAMID com.you.berms`, and clear old profiles under xcode settings → accounts.
- xcode won't run a build at all → `sudo xcodebuild -license accept`.

# iOS design standard

Berms must feel calm, precise, lightweight, and content-first, using the current Apple Human Interface Guidelines and iOS 27 Design Resources as design authority.

- Default to native SwiftUI: NavigationStack/NavigationSplitView, TabView, List, Form, toolbars, sheets, system detents, menus, alerts, and confirmation dialogs. Never recreate a system component. Prefer the least custom UI.
- Use system typography, Dynamic Type text styles, SF Symbols, semantic colors, safe areas, and native materials. Support light/dark appearance and Increased Contrast.
- Build adaptive layouts for all current iPhone sizes and appropriate landscape use. Important content must remain readable at the largest accessibility text sizes; reflow or scroll instead of truncating or shrinking it.
- Preserve native scrolling, swipe-back, and interaction behavior. Use native destructive roles and clear primary actions. Use appropriate context menus for secondary actions.
- Normally provide at least 44×44 pt interaction targets. Label icon-only actions for VoiceOver, avoid color-only meaning, honor Reduce Motion, and use animation and haptics only to communicate meaningful changes.
- Avoid decorative gradients, shadows, borders, excessive glass, floating pills, oversized utility headings, dashboard card grids, and unnecessary rounded containers or arbitrary radii.

Before each screen change, identify the primary task, closest native navigation/presentation pattern, standard components, and simplest hierarchy. Customize only after that structure works.

After each screen change, review hierarchy, spacing, typography, native components, light/dark appearance, Dynamic Type, VoiceOver, interaction states, and unnecessary decoration. Compare with Apple's current iOS 27 kit. Report which checks were actually performed and which require device review.

References:
- https://developer.apple.com/design/human-interface-guidelines/
- https://developer.apple.com/design/resources/

## Track screen layout

Preserve the centered start composition: center the icon, description, Start button, and supporting text in the available screen, with scrolling only when content does not fit. During recording, keep the map full-screen behind a compact floating stats panel above the tab bar. Size that panel to its content; never give it a large empty fixed-height background or replace it with an edge-to-edge bottom block. Keep the recording navigation chrome transparent and avoid a redundant Recording title. These are explicit user preferences from the September 9 visual review.

## Pre-release build identity

- Settings → About Berms Beta shows the build's Git commit, local-change status, and build time, with Share Build Details for comparing phones. Everything is embedded and works offline.
- The Berms target runs `scripts/write-build-identity.py` on every build, including Release/archive and incremental builds. It writes only into the built app, never into tracked source files.
- Build from a Git clone or worktree. Use the actual checkout's `HEAD`, never `main`, `origin/main`, commit counts, branch names, or a manually chosen version. Worktrees, detached checkouts, and shallow clones work without fetching.
- After merging a PR (including squash/rebase), build from updated main to distribute that main commit. A build made before merging still identifies its original commit; merging cannot change an already-installed app.
- No agent should ask what pre-release version to bump or manually bump versions for ordinary changes. Commit identity updates automatically. Keep Apple's numeric bundle versions separate from this source identity; any future TestFlight upload workflow must supply its own increasing numeric build number consistently across the app and extensions.
- Uncommitted tracked, staged, and untracked files mark a build as Local changes. Share details include a UTC build time to distinguish these builds; only clean builds can be identified by commit alone.
- Verify the generator with `python3 scripts/test-build-identity.py`.

## Lint and format

Swift formatting and linting use Apple's `swift-format` with the repo-root `.swift-format` config (4-space indent, 120-column lines, force-unwrap and `.forEach` rules on).

- Format everything: `./scripts/format.sh`
- Lint everything: `./scripts/lint.sh`
- Install the pre-commit hook that formats staged Swift files: `./scripts/install-hooks.sh`
- CI runs `./scripts/lint.sh` via `.github/workflows/lint.yml`

Run lint before committing; it must pass clean. Scripts prefer /Applications/Xcode.app when DEVELOPER_DIR is unset.

## Local device workflow

- For physical iPhone builds and installs, use the stable Xcode toolchain at /Applications/Xcode.app/Contents/Developer. The beta toolchain currently rejects Berms's legacy watchkit2-extension target.
- Use DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices to find the paired physical iPhone, and use its identifier for device work. Do not use a simulator for physical-device validation.
- Build for the connected device with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Berms.xcodeproj -scheme Berms -destination 'id=DEVICE_ID' -derivedDataPath /tmp/berms-device-build -allowProvisioningUpdates build.
- Install the signed app with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app --device DEVICE_ID /tmp/berms-device-build/Build/Products/Debug-iphoneos/Berms.app.
- Device installation requires a paired phone, an Apple account available to Xcode, and provisioning profiles that include Berms's HealthKit capability and its Watch targets.

## iOS Simulator interaction (AXe)

Use AXe (`axe`) for any task that requires interacting with the iOS Simulator; use normal shell/Xcode tooling for builds and installs. AXe needs a full Xcode selected, so prefix its commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless `xcode-select -p` already points at Xcode.

- Determine the target UDID first with `axe list-simulators`, then pass `--udid <UDID>` to every simulator command.
- Inspect the current UI with `axe describe-ui --udid <UDID>` before interacting, and re-inspect after any action that changes state.
- Prefer accessibility IDs and labels (`axe tap --id` / `--label`, `axe slider`) over screen coordinates.
- HID commands are fire-and-forget: verify the requested final state with `describe-ui` or `axe screenshot` instead of assuming a tap or type succeeded.
- Use screenshots when the accessibility hierarchy is insufficient.
- Use AXe 1.8.0 installed at /opt/homebrew/opt/axe/libexec with the wrapper at /opt/homebrew/bin/axe; the Homebrew formula install is blocked by the macOS 27 / Xcode 26.4.1 version check.
- Do not boot, erase, reset, or otherwise modify simulator state unless the task requires it, and shut down simulators you booted when finished.

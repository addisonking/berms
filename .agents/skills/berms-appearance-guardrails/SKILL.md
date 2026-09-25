---
name: berms-appearance-guardrails
description: "Use when changing colors, tints, materials, control styling, spacing, or animation in the Berms iOS app, or whenever a change must work in light and dark mode. Prevents the recurring monochrome-tint bug where switches render as solid white pills in dark mode, and pins the checks (simulator in both appearances, Dynamic Type, Reduce Motion) that must run before a UI change is called done."
---

# Berms appearance guardrails

## Why this exists

Berms sets one monochrome tint at the root (`RootView`: `.tint(.bermsTrail)` = `Color(uiColor: .label)`).
That is intentional for links, the tab bar, and toolbars, but it breaks any control whose ON state
is a filled tint: a `Toggle` tinted with `.label` is white track plus white knob in dark mode, so on
and off look identical. This has shipped more than once.

## Hard rules

1. Switches always set `.tint(Color.bermsSwitch)`. Never rely on the inherited root tint for a `Toggle`.
2. Treat an explicit `.tint(...)` or `.foregroundStyle(...)` as load-bearing. Before removing one as
   "redundant", screenshot that control in both appearances. Removing `.tint(.green)` from switches
   is what caused the invisible toggles.
3. Colors come from `Theme.swift` (`Color.berms*`). No raw `.green`/`.orange`/hex in views, no
   `.black` on accents except the jump tokens. Difficulty colors come from `bermsDifficulty`.
4. Spacing comes from `BermsSpacing` (`tight` 4, `compact` 8, `control` 12, `content` 16, `section` 24).
   No 3/5/30 magic paddings, no `cornerRadius:` literals.
5. Animation is gated: `reduceMotion ? nil : BermsMotion.*`. Never call `withAnimation` or `.animation`
   without that gate.
6. Meaning is never color-only. Pair color with a label, symbol, or position (jump markers carry numbers,
   time breakdown has labeled rows).
7. If a control is not a native system control, ask why. Prefer `List`, `Form`, `LabeledContent`,
   `ContentUnavailableView`, `NavigationLink` over hand-built rows.

## Verification loop for any UI change

Run this before saying a screen is done. Do not eyeball only the appearance you are currently in.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
UDID=$(xcrun simctl list devices available | rg -o '[0-9A-F-]{36}' | head -1)   # or a known iPhone

xcrun simctl install "$UDID" /tmp/berms-test-build/Build/Products/Debug-iphonesimulator/Berms.app
xcrun simctl launch "$UDID" com.addis.berms
axe describe-ui --udid "$UDID" >/dev/null        # confirm the screen you think is up
axe screenshot --udid "$UDID" --output /tmp/light.png

xcrun simctl ui "$UDID" appearance dark
axe screenshot --udid "$UDID" --output /tmp/dark.png
xcrun simctl ui "$UDID" appearance light         # always restore
```

Compare `/tmp/light.png` and `/tmp/dark.png`. Check specifically: switch states, selection states,
disabled states, materials over maps, and anything drawn on a dark sheet.

Also worth a pass when touching layout: largest accessibility text size on the screen you changed
(`axe` + Settings → Accessibility, or `xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large`),
and scrolled-to-bottom to catch footers that grew.

## Device builds

Simulator checks do not prove a device build. The device path needs an Apple ID signed into Xcode
(Settings → Accounts). If `xcodebuild` reports `No Accounts` for the watch targets, that is the cause,
not the project. Build and install with:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Berms.xcodeproj -scheme Berms -destination 'id=<DEVICE_ID>' \
  -derivedDataPath /tmp/berms-device-build -allowProvisioningUpdates build
xcrun devicectl device install app --device <DEVICE_ID> \
  /tmp/berms-device-build/Build/Products/Debug-iphoneos/Berms.app
```

## Related

- `ios-hig-design` and `swiftui-*` skills cover general SwiftUI and HIG practice.
- The repo's AGENTS.md is the design standard; this skill only pins the failure modes we keep hitting.

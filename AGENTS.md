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

## Local device workflow

- For physical iPhone builds and installs, use the stable Xcode toolchain at /Applications/Xcode.app/Contents/Developer. The beta toolchain currently rejects Berms's legacy watchkit2-extension target.
- Use DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices to find the paired physical iPhone, and use its identifier for device work. Do not use a simulator for physical-device validation.
- Build for the connected device with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Berms.xcodeproj -scheme Berms -destination 'id=DEVICE_ID' -derivedDataPath /tmp/berms-device-build -allowProvisioningUpdates build.
- Install the signed app with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app --device DEVICE_ID /tmp/berms-device-build/Build/Products/Debug-iphoneos/Berms.app.
- Device installation requires a paired phone, an Apple account available to Xcode, and provisioning profiles that include Berms's HealthKit capability and its Watch targets.

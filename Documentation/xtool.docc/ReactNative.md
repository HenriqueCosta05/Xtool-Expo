# Build React Native and Expo apps

Build, sign, and install a React Native or Expo app on Linux, WSL, or macOS.

## Overview

xtool builds React Native apps using the precompiled XCFrameworks and Swift Package Manager tooling that ship with React Native. It runs React Native's own SwiftPM pipeline, generates a small Swift package for your app, and then builds, signs, and installs it like any other xtool app.

> Note: This requires react-native 0.87 or newer (Expo SDK 56 or newer). Every native module you use must support SwiftPM: either ship a `Package.swift`, or ship precompiled XCFrameworks (most Expo modules do).

## Requirements

In addition to the steps in <doc:Installation-Linux>, install [Node.js](https://nodejs.org) 20 or newer, and Python 3 on Linux. Then install your app's dependencies:

```bash
npm install
```

Optionally add an `xtool.yml` to the root of your project to set the bundle ID. The same keys as for SwiftPM apps apply, except `product`.

```yaml
version: 1
bundleID: com.example.myapp
```

### App extensions

Declare app extensions (widgets, share extensions, and so on) under `extensions` as for SwiftPM apps. Since a React Native project has no `Package.swift`, xtool builds each extension from the Swift, Objective-C, and C sources in `targets/<product>`, or in the directory set by `sources`:

```yaml
extensions:
  - product: Widget
    infoPath: targets/Widget/Info.plist
    entitlementsPath: targets/Widget/Widget.entitlements
  - product: Share
    sources: native/share
    infoPath: native/share/Info.plist
```

Other files in that directory, such as `Info.plist` or entitlements, are ignored unless `xtool.yml` points to them. Extensions can use system frameworks, but not React Native or Swift package dependencies.

## Build and run

From the root of your project (the folder with `package.json`), run:

```bash
xtool dev
```

xtool detects the React Native project, prepares it in `xtool/rn`, and installs the app on your connected device.

### Debug builds

Debug builds load JavaScript from the Metro dev server, so start it in a separate terminal:

```bash
npx expo start  # or: npx react-native start
```

The app connects to Metro using your machine's IP address. To use a different host, set `XTOOL_METRO_HOST`:

```bash
XTOOL_METRO_HOST=192.168.1.20 xtool dev
```

> Important: On WSL 2 the default NAT network isn't reachable from your phone. Enable [mirrored networking mode](https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking) so that WSL shares your PC's IP address, and allow port 8081 through the Windows firewall.

To run a Debug build without Metro, embed the JavaScript bundle in the app instead:

```bash
xtool dev --embed-bundle
```

The bundle is built in development mode, so warnings and LogBox still show, but changes to your JavaScript need a rebuild.

### Expo on Linux (beta)

Some of Expo's native tooling only ships for macOS, so on Linux xtool builds it from your `node_modules` the first time you build an Expo app:

- `expo-modules-macros`: compiled for Linux, replacing the macOS binary inside `node_modules` (the original is kept as `ExpoModulesMacros.darwin`). This takes a few minutes.
- `expo-modules-jsi`: built as a framework with the iOS SDK when the installed version doesn't ship one, and linked into the app (Expo normally builds it in an Xcode build phase).
- Expo modules that mix Swift and Objective-C, declare an `spm.config.json`, and aren't published prebuilt (for example `@expo/ui`, `expo-audio`, `expo-application`): each one is built into the Debug and Release XCFrameworks that Expo's Swift Package Manager integration expects, under `xtool/rn/expo-precompiled`, which xtool passes as `EXPO_PRECOMPILED_MODULES_PATH`. Modules that ship only Swift sources or their own `Package.swift` are built from source as usual.

All of these are reused on later builds and rebuilt when the module, or the Expo modules it depends on, change version. Reinstalling `node_modules` triggers the macro build again.

Because these frameworks come from `EXPO_PRECOMPILED_MODULES_PATH` while `ExpoModulesCore` comes from npm, Expo prints a `WARNING` about mixing precompiled modules from different places. It's expected: xtool builds them against the exact `ExpoModulesCore` in your `node_modules`.

Modules that mix languages but declare neither an `spm.config.json` nor a `Package.swift` (such as `expo-dev-launcher` and `expo-dev-menu`, which `expo-dev-client` pulls in) can't be built with Swift Package Manager. Exclude them from iOS autolinking in your `package.json`:

```json
"expo": { "autolinking": { "ios": { "exclude": ["expo-dev-client", "expo-dev-launcher", "expo-dev-menu"] } } }
```

> Warning: Build-time script phases declared by Expo modules (for example `expo-constants` embedding your app config) are not run yet.

### Release builds

Release builds embed the JavaScript bundle and assets in the app, so they run without Metro:

```bash
xtool dev run -c release
xtool dev build -c release --ipa
```

# Expose App Intents to Siri and Shortcuts

Make your `AppIntent`s and App Shortcuts discoverable when building on Linux.

## Overview

iOS doesn't find App Intents by scanning your binary. It reads a `Metadata.appintents` folder in the app bundle, which Xcode generates at build time with `appintentsmetadataprocessor`. That tool only runs on macOS, so xtool generates the folder itself from the constant values that the Swift compiler extracts from your code. Without it your intents still compile, but Siri and the Shortcuts app never see them.

This happens automatically when you build with `xtool dev`, for the app and for each app extension: xtool looks for intents in the Swift modules each one links. If your code uses something xtool can't describe yet, the build prints a `warning: App Intents:` line and leaves that piece out.

```swift
import AppIntents

struct CallWithReasonIntent: AppIntent {
    static let title: LocalizedStringResource = "Call with reason"
    static let description = IntentDescription("Calls a contact and tells them why.")

    @Parameter(title: "Reason")
    var reason: String

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CallWithReasonIntent(),
            phrases: ["Call with a reason in \(.applicationName)"],
            shortTitle: "Call with reason",
            systemImageName: "phone"
        )
    }
}
```

## Supported features

> Warning: This support is experimental. The metadata format is undocumented, and xtool mirrors what Xcode 26 writes.

- `AppIntent` types with a literal `title`, and optionally `description`, `openAppWhenRun` and `isDiscoverable`.
- `@Parameter`s of type `String` or `Bool`, optional or not, with a literal `title`, `description` and `default`.
- `@available` annotations on intents.
- One `AppShortcutsProvider` per app or extension, whose phrases are string literals that interpolate only `.applicationName`.

Not supported yet: parameters of other types (such as `Int`, `Date`, `AppEntity` and `AppEnum`), entities and queries, intents with special roles (such as `WidgetConfigurationIntent` and `LiveActivityIntent`), `AppIntentsPackage`, and phrases that interpolate parameters. Siri also matches App Shortcut phrases less flexibly than in apps built with Xcode, which trains a language model on them.

These values must be literals in your source code: xtool can't read values that are computed at run time.

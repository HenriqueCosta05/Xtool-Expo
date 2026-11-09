import Foundation
import Testing
@testable import ReactNativeSupport

private func makeProject(files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, contents) in files {
        try Data(contents.utf8).write(to: dir.appendingPathComponent(name))
    }
    return dir
}

@Test func detectsExpoProject() throws {
    let dir = try makeProject(files: [
        "package.json": #"{"name": "my-app", "dependencies": {"expo": "~58.0.0", "react-native": "0.88.0"}}"#,
        "app.json": #"{"expo": {"name": "My Cool App"}}"#,
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    let project = try #require(try ReactNativeProject(directory: dir))
    #expect(project.isExpo)
    #expect(project.productName == "MyCoolApp")
}

@Test func ignoresNonReactNativeProjects() throws {
    let swiftPackage = try makeProject(files: [
        "Package.swift": "",
        "package.json": #"{"dependencies": {"react-native": "0.88.0"}}"#,
    ])
    let webApp = try makeProject(files: ["package.json": #"{"dependencies": {"react": "19.0.0"}}"#])
    defer {
        try? FileManager.default.removeItem(at: swiftPackage)
        try? FileManager.default.removeItem(at: webApp)
    }

    #expect(try ReactNativeProject(directory: swiftPackage) == nil)
    #expect(try ReactNativeProject(directory: webApp) == nil)
}

@Test func resolvesRelativePaths() {
    let root = URL(fileURLWithPath: "/work/app")
    #expect(ReactNativeProject.absolute("assets/icon.png", in: root) == "/work/app/assets/icon.png")
    #expect(ReactNativeProject.absolute("/abs/icon.png", in: root) == "/abs/icon.png")
}

@Test func shellManifestLinksRuntimeFrameworks() {
    let package = ShellPackage(productName: "Demo", moduleName: "main", isExpo: true, frameworks: ["React", "hermesvm"])
    let manifest = package.manifest

    #expect(manifest.contains(#".library(name: "Demo", targets: ["Demo"])"#))
    #expect(manifest.contains(#""hermesvm","#))
    #expect(manifest.contains(#".binaryTarget(name: "React", path: "Frameworks/React.xcframework"),"#))
    #expect(manifest.contains(#".package(name: "Autolinked", path: "build/generated/autolinking")"#))
}

@Test func appDelegateMatchesProjectFlavor() {
    let bare = ShellPackage(productName: "Demo", moduleName: "Demo", isExpo: false, frameworks: []).appDelegate
    #expect(bare.contains("final class AppDelegate: UIResponder, UIApplicationDelegate"))
    #expect(bare.contains(#"forBundleRoot: "index""#))
    #expect(!bare.contains("import Expo"))

    let expo = ShellPackage(productName: "Demo", moduleName: "main", isExpo: true, frameworks: []).appDelegate
    #expect(expo.contains("final class AppDelegate: ExpoAppDelegate"))
    #expect(expo.contains("override func application("))
    #expect(expo.contains(#"withModuleName: "main""#))
}

@Test func stubProjectUsesXcodeLayout() {
    let project = ShellPackage.stubProject
    #expect(project.contains("/* Begin PBXNativeTarget section */"))
    #expect(project.contains("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = \(ShellPackage.deploymentTarget);"))
    #expect(!project.contains("    "))
}

@Test func globMatchesSPMConfigPatterns() throws {
    let sources = try #require(Glob("**/*.{m,mm}"))
    #expect(sources.matches("Helper.mm"))
    #expect(sources.matches("Nested/Dir/Helper.m"))
    #expect(!sources.matches("Helper.swift"))

    let topLevel = try #require(Glob("*.swift"))
    #expect(topLevel.matches("Module.swift"))
    #expect(!topLevel.matches("Nested/Module.swift"))

    let tests = try #require(Glob("Tests/**"))
    #expect(tests.matches("Tests/Foo/Bar.m"))
    #expect(!tests.matches("Sources/Tests.m"))
}

private func makeExpoModule(config: String, files: [String: String]) throws -> URL {
    let root = try makeProject(files: ["package.json": #"{"version": "1.0.0"}"#, "spm.config.json": config])
    for (path, contents) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    return root
}

private let mixedConfig = #"""
{"products": [{
  "name": "ExpoThing",
  "externalDependencies": ["React", "expo-modules-core/ExpoModulesCore"],
  "targets": [
    {"type": "objc", "name": "ExpoThing_ios_objc", "moduleName": "ExpoThing", "path": "ios",
     "pattern": "**/*.m", "headerPattern": "**/*.h", "exclude": ["Tests/**"], "includeDirectories": ["."]},
    {"type": "swift", "name": "ExpoThing", "path": "ios", "pattern": "**/*.swift",
     "dependencies": ["React", "expo-modules-core/ExpoModulesCore", "ExpoThing_ios_objc"],
     "linkedFrameworks": ["UIKit"]}
  ]
}]}
"""#

@Test func discoversMixedExpoModulesWithoutPrebuilds() throws {
    let mixed = try makeExpoModule(config: mixedConfig, files: [
        "ios/Thing.swift": "", "ios/Helper.m": "", "ios/Helper.h": "", "ios/Tests/HelperTests.m": "",
    ])
    let pureSwift = try makeExpoModule(config: mixedConfig, files: ["ios/Thing.swift": "", "ios/Tests/HelperTests.m": ""])
    let withManifest = try makeExpoModule(config: mixedConfig, files: ["ios/Helper.m": "", "Package.swift": ""])
    let published = try makeExpoModule(config: mixedConfig, files: [
        "ios/Helper.m": "",
        "prebuilds/output/debug/xcframeworks/ExpoThing.tar.gz": "",
        "prebuilds/output/release/xcframeworks/ExpoThing.tar.gz": "",
    ])
    defer {
        for dir in [mixed, pureSwift, withManifest, published] {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    let prebuilds = ExpoPrebuild.discover(modules: [
        ("mixed", mixed), ("pure-swift", pureSwift), ("with-manifest", withManifest), ("published", published),
    ])
    #expect(prebuilds.map(\.packageName) == ["mixed"])

    let prebuild = try #require(prebuilds.first)
    #expect(prebuild.unsupportedReason == nil)
    #expect(prebuild.needsUnderlyingModule)
    #expect(prebuild.headersTarget?.name == "ExpoThing_ios_objc")
    #expect(prebuild.expoDependencies.map(\.product) == ["ExpoModulesCore"])

    let objc = try #require(prebuild.product.targets.first)
    #expect(ExpoPrebuild.files(matching: "**/*.m", in: objc, moduleRoot: mixed) == ["Helper.m"])
}

@Test func expoPrebuildManifestAndModuleMap() throws {
    let config = try JSONDecoder().decode(SPMConfig.self, from: Data(mixedConfig.utf8))
    let prebuild = ExpoPrebuild(packageName: "expo-thing", moduleRoot: URL(fileURLWithPath: "/m"), product: config.products[0])

    let manifest = prebuild.manifest(
        binaryTargets: ["React", "ExpoModulesCore"], swiftFlags: ["-import-underlying-module"], clangFlags: []
    )
    #expect(manifest.contains(#".library(name: "ExpoThing", type: .dynamic, targets: ["ExpoThing_ios_objc", "ExpoThing"])"#))
    #expect(manifest.contains(#".binaryTarget(name: "ExpoModulesCore", path: "Frameworks/ExpoModulesCore.xcframework")"#))
    #expect(manifest.contains(#".target(name: "ExpoThing_ios_objc")"#))
    #expect(manifest.contains(#"publicHeadersPath: "xtool-public""#))
    #expect(manifest.contains(#".headerSearchPath(".")"#))
    #expect(manifest.contains(#".linkedFramework("UIKit")"#))
    #expect(manifest.contains("swiftLanguageModes: [.v5]"))

    let moduleMap = prebuild.frameworkModuleMap(hasHeaders: true, swiftHeader: "ExpoThing-Swift.h")
    #expect(moduleMap.hasPrefix("framework module ExpoThing {\n    use React\n    umbrella header \"ExpoThing_umbrella.h\""))
    #expect(moduleMap.contains(#"header "ExpoThing-Swift.h""#))

    let artifacts = ExpoPrebuild.artifactDirectory(in: URL(fileURLWithPath: "/p"), packageName: "@expo/ui", flavor: "debug")
    #expect(artifacts.path == "/p/@expo/ui/output/debug/xcframeworks")
}

@Test func shellManifestDeclaresExtensions() {
    let package = ShellPackage(
        productName: "Demo", moduleName: "main", isExpo: true, frameworks: ["React"], extensions: ["Widget"]
    )
    let manifest = package.manifest
    #expect(manifest.contains(#".library(name: "Widget", targets: ["Widget"]),"#))
    #expect(manifest.contains(#"path: "Extensions/Widget","#))
}

@Test func appDelegateCanEmbedBundleInDebug() {
    let metro = ShellPackage(productName: "Demo", moduleName: "main", isExpo: true, frameworks: []).appDelegate
    #expect(metro.contains("RCTBundleURLProvider"))

    let embedded = ShellPackage(
        productName: "Demo", moduleName: "main", isExpo: true, frameworks: [], embedBundle: true
    ).appDelegate
    #expect(!embedded.contains("RCTBundleURLProvider"))
    #expect(!embedded.contains("#if DEBUG"))
    #expect(embedded.contains(#"Bundle.main.url(forResource: "main", withExtension: "jsbundle")"#))
}

@Test func readsExtensionSourcesFromConfig() throws {
    let dir = try makeProject(files: [
        "xtool.yml": """
        version: 1
        orgID: com.example
        extensions:
          - product: Widget
            infoPath: targets/Widget/Info.plist
          - product: Share
            infoPath: share/Info.plist
            sources: share
        """,
    ])
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(throws: (any Error).self) { try UserConfig(projectRoot: dir).extensionSources(productName: "Demo") }

    for path in ["targets/Widget/Nested", "share"] {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    let config = try UserConfig(projectRoot: dir)
    let sources = try config.extensionSources(productName: "Demo")
    #expect(sources.map(\.name) == ["Widget", "Share"])
    #expect(sources.map(\.sources.lastPathComponent) == ["Widget", "share"])
    #expect(config.schema.extensions?.map(\.product) == ["Widget", "Share"])

    #expect(throws: (any Error).self) { try config.extensionSources(productName: "Widget") }
}

@Test func mirrorsOnlySourceFiles() throws {
    let source = try makeProject(files: ["Widget.swift": "", "Info.plist": "", "Widget.entitlements": ""])
    let nested = source.appendingPathComponent("Views")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data().write(to: nested.appendingPathComponent("View.swift"))
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: destination)
    }

    try ReactNativeProject.mirrorSources(of: source, into: destination)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["Views", "Widget.swift"])
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Views/View.swift").path))
}

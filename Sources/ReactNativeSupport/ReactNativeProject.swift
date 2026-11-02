import Foundation
import PackLib
import XUtils
import Yams

public struct ReactNativeProject: Sendable {
    public let root: URL
    let isExpo: Bool
    let appName: String

    var appRoot: URL { root.appendingPathComponent("xtool/rn", isDirectory: true) }

    public init?(directory: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
              let data = fileManager.contents(atPath: directory.appendingPathComponent("package.json").path)
        else { return nil }

        let manifest = try JSONDecoder().decode(NodeManifest.self, from: data)
        let dependencies = (manifest.dependencies ?? [:]).merging(manifest.devDependencies ?? [:]) { $1 }
        guard dependencies["react-native"] != nil else { return nil }

        let isExpo = dependencies["expo"] != nil
        self.root = directory.absoluteURL.standardizedFileURL
        self.isExpo = isExpo
        self.appName = AppConfig.name(in: directory, isExpo: isExpo) ?? manifest.name ?? "App"
    }

    var productName: String {
        let name = appName.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return name.first?.isLetter == true ? name : "App"
    }

    public func prepare(configuration: BuildConfiguration) async throws -> URL {
        let setupScript = root.appendingPathComponent("node_modules/react-native/scripts/setup-apple-spm.js")
        guard FileManager.default.fileExists(atPath: setupScript.path) else {
            throw StringError("""
            React Native's SwiftPM tooling was not found in node_modules. \
            Run `npm install`, and make sure you're on react-native 0.87+ (Expo SDK 56+).
            """)
        }

        print("Preparing React Native project...")
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
        try write(ShellPackage.stubProject, to: "App.xcodeproj/project.pbxproj")

        let pipeline = NodePipeline(projectRoot: root, appRoot: appRoot, isExpo: isExpo)
        try await pipeline.generatePackages()
        let bundleResources = try await pipeline.prepareBundle(configuration: configuration)

        let package = ShellPackage(
            productName: productName,
            moduleName: isExpo ? "main" : appName,
            isExpo: isExpo,
            frameworks: try linkFrameworks(flavor: configuration.rawValue)
        )
        try writeSources(of: package)
        try writeSchema(resources: bundleResources)
        return appRoot
    }

    private func linkFrameworks(flavor: String) throws -> [String] {
        var sources: [String: URL] = [:]

        let rnManifest = appRoot.appendingPathComponent("build/xcframeworks/flavored-frameworks.json")
        for framework in try decode(FlavoredFrameworks.self, from: rnManifest)?.frameworks ?? [] {
            sources[framework.frameworkName] = appRoot
                .appendingPathComponent("build/xcframeworks/\(flavor)/\(framework.artifactRelativePath)")
        }

        let pluginManifest = appRoot.appendingPathComponent("build/generated/autolinking/.spm-plugin-flavored-frameworks.json")
        for framework in try decode([PluginFramework].self, from: pluginManifest) ?? [] {
            guard let path = framework.flavors[flavor] else { continue }
            sources[framework.frameworkName] = sources[framework.frameworkName] ?? URL(fileURLWithPath: path)
        }

        // Expo builds ExpoModulesJSI in an Xcode build phase rather than declaring it to SwiftPM,
        // so link the copy ExpoLinuxSupport built.
        let jsi = ExpoPrebuild.artifactDirectory(
            in: appRoot.appendingPathComponent("expo-precompiled"), packageName: "expo-modules-jsi", flavor: flavor
        ).appendingPathComponent("ExpoModulesJSI.xcframework")
        if isExpo, sources["ExpoModulesJSI"] == nil, FileManager.default.fileExists(atPath: jsi.path) {
            sources["ExpoModulesJSI"] = jsi
        }

        let frameworksDir = appRoot.appendingPathComponent("Frameworks", isDirectory: true)
        try? FileManager.default.removeItem(at: frameworksDir)
        try FileManager.default.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
        for (name, source) in sources {
            try FileManager.default.createSymbolicLink(
                at: frameworksDir.appendingPathComponent("\(name).xcframework"),
                withDestinationURL: source
            )
        }
        return sources.keys.sorted()
    }

    private func writeSources(of package: ShellPackage) throws {
        let sourcesDir = appRoot.appendingPathComponent("App", isDirectory: true)
        try? FileManager.default.removeItem(at: sourcesDir)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        try write(package.manifest, to: "Package.swift")
        try write(package.appDelegate, to: "App/AppDelegate.swift")

        let generated = appRoot.appendingPathComponent("build/generated/autolinking/.spm-plugin-generated-sources.json")
        for source in try decode([GeneratedSource].self, from: generated) ?? [] {
            let url = URL(fileURLWithPath: Self.absolute(source.path, in: appRoot))
            try FileManager.default.createSymbolicLink(
                at: sourcesDir.appendingPathComponent(url.lastPathComponent),
                withDestinationURL: url
            )
        }
    }

    private func writeSchema(resources: [String]) throws {
        let userConfig = root.appendingPathComponent("xtool.yml")
        var schema: PackSchemaBase
        if let data = FileManager.default.contents(atPath: userConfig.path) {
            schema = try YAMLDecoder().decode(PackSchemaBase.self, from: data)
        } else {
            print("warning: Could not locate 'xtool.yml'. Using default configuration with 'com.example' organization ID.")
            schema = try YAMLDecoder().decode(PackSchemaBase.self, from: "version: 1\norgID: com.example")
        }

        let absolute = { (path: String) in Self.absolute(path, in: root) }
        schema.product = productName
        schema.infoPath = try writeInfoPlist(merging: schema.infoPath.map(absolute))
        schema.iconPath = schema.iconPath.map(absolute)
        schema.entitlementsPath = schema.entitlementsPath.map(absolute)
        schema.resources = (schema.resources ?? []).map(absolute) + resources
        schema.extensions = nil
        schema.skipLSP = true

        try write(try YAMLEncoder().encode(schema), to: "xtool.yml")
    }

    private func writeInfoPlist(merging userPlist: String?) throws -> String {
        var info: [String: Any] = [:]
        if let userPlist, let data = FileManager.default.contents(atPath: userPlist) {
            info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        }
        info["NSAppTransportSecurity"] = info["NSAppTransportSecurity"] ?? ["NSAllowsLocalNetworking": true]

        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: appRoot.appendingPathComponent("Info.plist"))
        return "Info.plist"
    }

    private func write(_ contents: String, to path: String) throws {
        let url = appRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    static func absolute(_ path: String, in directory: URL) -> String {
        path.hasPrefix("/") ? path : directory.appendingPathComponent(path).path
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct NodeManifest: Decodable {
    var name: String?
    var dependencies: [String: String]?
    var devDependencies: [String: String]?
}

private struct AppConfig: Decodable {
    struct Expo: Decodable { var name: String? }

    var name: String?
    var expo: Expo?

    static func name(in directory: URL, isExpo: Bool) -> String? {
        guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent("app.json").path),
              let config = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        return isExpo ? config.expo?.name : config.name
    }
}

private struct FlavoredFrameworks: Decodable {
    struct Framework: Decodable {
        var frameworkName: String
        var artifactRelativePath: String
    }

    var frameworks: [Framework]
}

private struct PluginFramework: Decodable {
    var frameworkName: String
    var flavors: [String: String]
}

private struct GeneratedSource: Decodable {
    var path: String
}

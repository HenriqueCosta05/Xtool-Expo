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

    /// Prepares the shell Swift package in `xtool/rn` and returns its directory.
    ///
    /// - Parameter embedBundle: Embed the JavaScript bundle in Debug builds too, so the app
    ///   runs without the Metro dev server. Release builds always embed it.
    public func prepare(configuration: BuildConfiguration, embedBundle: Bool = false) async throws -> URL {
        let setupScript = root.appendingPathComponent("node_modules/react-native/scripts/setup-apple-spm.js")
        guard FileManager.default.fileExists(atPath: setupScript.path) else {
            throw StringError("""
            React Native's SwiftPM tooling was not found in node_modules. \
            Run `npm install`, and make sure you're on react-native 0.87+ (Expo SDK 56+).
            """)
        }

        let config = try UserConfig(projectRoot: root)
        let appSources = try config.appSources()
        let extensions = try config.extensionSources(productName: productName, appSources: appSources)

        print("Preparing React Native project...")
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
        try write(ShellPackage.stubProject, to: "App.xcodeproj/project.pbxproj")

        let pipeline = NodePipeline(projectRoot: root, appRoot: appRoot, isExpo: isExpo)
        try await pipeline.generatePackages()
        let bundleResources = try await pipeline.prepareBundle(configuration: configuration, embed: embedBundle)

        let package = ShellPackage(
            productName: productName,
            moduleName: isExpo ? "main" : appName,
            isExpo: isExpo,
            frameworks: try linkFrameworks(flavor: configuration.rawValue),
            extensions: extensions.map(\.name),
            embedBundle: embedBundle
        )
        try writeSources(of: package, appSources: appSources, extensions: extensions)
        try writeSchema(config.schema, resources: bundleResources)
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

    private func writeSources(of package: ShellPackage, appSources: URL?, extensions: [ExtensionSource]) throws {
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

        if let appSources {
            try Self.mirrorSources(of: appSources, into: sourcesDir)
        }

        let extensionsDir = appRoot.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.removeItem(at: extensionsDir)
        for ext in extensions {
            try Self.mirrorSources(of: ext.sources, into: extensionsDir.appendingPathComponent(ext.name))
        }
    }

    /// SwiftPM targets must live inside the package, so recreate the directory tree under it with
    /// each source file symlinked to the original. Other files (Info.plist, entitlements, assets)
    /// are left out: they're configured in `xtool.yml`, and SwiftPM would warn about them.
    static func mirrorSources(of source: URL, into destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) where !name.hasPrefix(".") {
            let item = source.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try mirrorSources(of: item, into: destination.appendingPathComponent(name))
            } else if sourceExtensions.contains(item.pathExtension) {
                let link = destination.appendingPathComponent(name)
                guard !fileManager.fileExists(atPath: link.path) else {
                    throw StringError("""
                    '\(item.path)' clashes with a file that xtool generates (such as AppDelegate.swift). Rename it.
                    """)
                }
                try fileManager.createSymbolicLink(at: link, withDestinationURL: item)
            }
        }
    }

    private static let sourceExtensions: Set<String> = ["swift", "h", "hpp", "m", "mm", "c", "cc", "cpp", "modulemap"]

    private func writeSchema(_ userSchema: PackSchemaBase, resources: [String]) throws {
        var schema = userSchema
        let absolute = { (path: String) in Self.absolute(path, in: root) }
        schema.product = productName
        schema.infoPath = try writeInfoPlist(merging: schema.infoPath.map(absolute))
        schema.iconPath = schema.iconPath.map(absolute)
        schema.entitlementsPath = schema.entitlementsPath.map(absolute)
        schema.resources = (schema.resources ?? []).map(absolute) + resources
        schema.extensions = schema.extensions?.map { ext in
            var ext = ext
            ext.infoPath = absolute(ext.infoPath)
            ext.entitlementsPath = ext.entitlementsPath.map(absolute)
            ext.resources = ext.resources?.map(absolute)
            return ext
        }
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

struct ExtensionSource {
    var name: String
    var sources: URL
}

/// The project's `xtool.yml`, plus the keys only React Native projects use.
struct UserConfig {
    /// React Native projects have no Package.swift to declare extension targets in,
    /// so each extension also says where its sources are.
    private struct Overlay: Decodable {
        struct Extension: Decodable {
            var product: String
            var sources: String?
        }

        /// Native sources compiled into the app itself, next to the generated AppDelegate.
        var sources: String?
        var extensions: [Extension]?
    }

    static let defaultAppSources = "targets/App"

    var schema: PackSchemaBase
    private var overlay: Overlay
    private var projectRoot: URL

    init(projectRoot: URL) throws {
        self.projectRoot = projectRoot
        let url = projectRoot.appendingPathComponent("xtool.yml")
        if let data = FileManager.default.contents(atPath: url.path) {
            schema = try YAMLDecoder().decode(PackSchemaBase.self, from: data)
            overlay = try YAMLDecoder().decode(Overlay.self, from: data)
        } else {
            print("warning: Could not locate 'xtool.yml'. Using default configuration with 'com.example' organization ID.")
            schema = try YAMLDecoder().decode(PackSchemaBase.self, from: "version: 1\norgID: com.example")
            overlay = Overlay()
        }
    }

    /// The directory of native sources to add to the app target, if any. It's optional,
    /// unless `xtool.yml` names one explicitly.
    func appSources() throws -> URL? {
        let path = overlay.sources ?? Self.defaultAppSources
        let url = URL(fileURLWithPath: ReactNativeProject.absolute(path, in: projectRoot)).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        guard overlay.sources == nil else {
            throw StringError("xtool.yml: Could not find the app's native sources at '\(path)'.")
        }
        return nil
    }

    func extensionSources(productName: String, appSources: URL? = nil) throws -> [ExtensionSource] {
        var seen: Set<String> = [productName]
        return try (overlay.extensions ?? []).map { ext in
            guard ext.product.first?.isLetter == true,
                  ext.product.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            else {
                throw StringError("xtool.yml: Extension product '\(ext.product)' must be a valid Swift module name.")
            }
            guard seen.insert(ext.product).inserted else {
                throw StringError("xtool.yml: Extension product '\(ext.product)' clashes with another product.")
            }
            let path = ext.sources ?? "targets/\(ext.product)"
            let url = URL(fileURLWithPath: ReactNativeProject.absolute(path, in: projectRoot))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw StringError("""
                xtool.yml: Could not find the sources of extension '\(ext.product)' at '\(path)'. \
                Create that directory, or set 'sources' on the extension.
                """)
            }
            guard url.standardizedFileURL != appSources else {
                throw StringError("xtool.yml: Extension '\(ext.product)' can't use the app's own sources directory '\(path)'.")
            }
            return ExtensionSource(name: ext.product, sources: url.standardizedFileURL)
        }
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

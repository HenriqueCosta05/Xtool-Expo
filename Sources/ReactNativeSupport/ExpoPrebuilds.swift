import Foundation

/// The subset of an Expo module's `spm.config.json` that xtool can build into a prebuilt XCFramework.
struct SPMConfig: Decodable, Sendable {
    struct Product: Decodable, Sendable {
        var name: String
        var externalDependencies: [String]?
        var excludeFromUmbrella: [String]?
        var targets: [Target]
        var customBuild: Unsupported?
        var sourceOnly: Unsupported?
    }

    struct Target: Decodable, Sendable {
        var type: String
        var name: String
        var moduleName: String?
        var path: String
        var pattern: String?
        var headerPattern: String?
        var exclude: [String]?
        var dependencies: [String]?
        var linkedFrameworks: [String]?
        var includeDirectories: [String]?
        var resources: [Resource]?
        var compilerFlags: Unsupported?
        var fileMapping: Unsupported?
        var moduleMapContent: Unsupported?

        var isClang: Bool { type == "objc" || type == "cpp" }
    }

    struct Resource: Decodable, Sendable {
        var path: String
    }

    /// Any value: only its presence matters.
    struct Unsupported: Decodable, Sendable {
        init(from decoder: Decoder) throws {}
    }

    var products: [Product]
}

/// One `spm.config.json` product that Expo doesn't publish prebuilt and that the Expo SwiftPM
/// plugin can't build from source either, so xtool builds it into the XCFramework pair the
/// plugin looks for under `EXPO_PRECOMPILED_MODULES_PATH`.
struct ExpoPrebuild: Sendable {
    var packageName: String
    var moduleRoot: URL
    var product: SPMConfig.Product

    static let flavors = ["debug", "release"]

    /// Artifact directory for `packageName` under a precompiled-modules root, as the plugin resolves it.
    static func artifactDirectory(in root: URL, packageName: String, flavor: String) -> URL {
        root.appendingPathComponent("\(packageName)/output/\(flavor)/xcframeworks", isDirectory: true)
    }

    /// The products of the given modules that need a prebuild. A module is skipped when it ships
    /// a `Package.swift` or only Swift sources, since the plugin builds those from source; a
    /// product is skipped when the npm package already ships its Debug and Release artifacts.
    static func discover(modules: [(packageName: String, moduleRoot: URL)]) -> [ExpoPrebuild] {
        var seen: Set<String> = []
        return modules.flatMap { packageName, moduleRoot -> [ExpoPrebuild] in
            let fileManager = FileManager.default
            guard seen.insert(moduleRoot.standardizedFileURL.path).inserted,
                  !fileManager.fileExists(atPath: moduleRoot.appendingPathComponent("Package.swift").path),
                  let data = fileManager.contents(atPath: moduleRoot.appendingPathComponent("spm.config.json").path),
                  let config = try? JSONDecoder().decode(SPMConfig.self, from: data),
                  hasClangSources(moduleRoot)
            else { return [] }

            let bundled = moduleRoot.appendingPathComponent("prebuilds", isDirectory: true)
            // Expo's prebuild pipeline doesn't build custom or source-only products either.
            return config.products
                .filter { !$0.targets.isEmpty && $0.customBuild == nil && $0.sourceOnly == nil }
                .filter { product in
                    !flavors.allSatisfy { flavor in
                        artifact(named: product.name, in: bundled.appendingPathComponent("output/\(flavor)/xcframeworks")) != nil
                    }
                }
                .map { ExpoPrebuild(packageName: packageName, moduleRoot: moduleRoot, product: $0) }
        }
    }

    /// `<name>.xcframework` or `<name>.tar.gz` in `directory`, whichever exists.
    static func artifact(named name: String, in directory: URL) -> URL? {
        ["\(name).xcframework", "\(name).tar.gz"]
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Mirrors the plugin's classification: a module is pure Swift unless its `ios` or `apple`
    /// directory holds C-family sources outside test and build directories.
    private static func hasClangSources(_ moduleRoot: URL) -> Bool {
        let ignored: Set<String> = ["Test", "Tests", "__tests__", "node_modules", "build", ".build"]
        let extensions: Set<String> = ["m", "mm", "c", "cpp", "cc"]
        for dir in ["ios", "apple"] {
            let root = moduleRoot.appendingPathComponent(dir, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            for case let url as URL in enumerator {
                if ignored.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                } else if extensions.contains(url.pathExtension) {
                    return true
                }
            }
        }
        return false
    }

    /// Why xtool can't build this product, if it can't.
    var unsupportedReason: String? {
        if let target = product.targets.first(where: { $0.type != "swift" && !$0.isClang }) {
            return "target \(target.name) has type '\(target.type)'"
        }
        if let target = product.targets.first(where: {
            $0.compilerFlags != nil || $0.fileMapping != nil || $0.moduleMapContent != nil
        }) {
            return "target \(target.name) uses compilerFlags, fileMapping or moduleMapContent"
        }
        if mainTarget == nil {
            return "no target is named \(product.name)"
        }
        return nil
    }

    var swiftTarget: SPMConfig.Target? {
        product.targets.first { $0.type == "swift" && $0.name == product.name }
    }

    /// The Clang target whose headers form the framework's module.
    var headersTarget: SPMConfig.Target? {
        product.targets.first { $0.isClang && ($0.moduleName ?? $0.name) == product.name }
    }

    var mainTarget: SPMConfig.Target? {
        swiftTarget ?? product.targets.first { $0.isClang && $0.name == product.name }
    }

    /// Whether the Swift target has to import a separately compiled Clang target as its own module,
    /// the way a mixed-language framework does.
    var needsUnderlyingModule: Bool {
        guard swiftTarget != nil, let headersTarget else { return false }
        return headersTarget.name != product.name
    }

    /// Expo modules this product links, as `(package, product)`.
    var expoDependencies: [(packageName: String, product: String)] {
        (product.externalDependencies ?? []).compactMap { dependency in
            guard let slash = dependency.lastIndex(of: "/") else { return nil }
            return (String(dependency[..<slash]), String(dependency[dependency.index(after: slash)...]))
        }
    }

    /// Paths relative to `target.path` of the files that `pattern` matches and `exclude` doesn't.
    static func files(matching pattern: String, in target: SPMConfig.Target, moduleRoot: URL) -> [String] {
        let root = moduleRoot.appendingPathComponent(target.path, isDirectory: true).standardizedFileURL
        guard let include = Glob(pattern),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        let excludes = (target.exclude ?? []).compactMap(Glob.init)
        var files: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if include.matches(relative), !excludes.contains(where: { $0.matches(relative) }) {
                files.append(relative)
            }
        }
        return files.sorted()
    }

    /// The `Package.swift` that compiles this product into a dynamic library against the
    /// `Frameworks/<name>.xcframework` of each of `binaryTargets`.
    func manifest(binaryTargets: [String], swiftFlags: [String], clangFlags: [String]) -> String {
        let quote = { (value: String) in "\"\(value)\"" }
        let list = { (values: [String]) in values.map(quote).joined(separator: ", ") }
        let localNames = Set(product.targets.map(\.name))

        let targets = product.targets.map { target in
            let dependencies = binaryTargets.map { ".target(name: \(quote($0)))" }
                + (target.dependencies ?? []).filter(localNames.contains).map { ".target(name: \(quote($0)))" }
            let frameworks = (target.linkedFrameworks ?? []).map { ".linkedFramework(\(quote($0)))" }
            var arguments = [
                "name: \(quote(target.name))",
                "dependencies: [\(dependencies.joined(separator: ", "))]",
                "path: \(quote("Sources/\(target.name)"))",
            ]
            if target.isClang {
                let searchPaths = (target.includeDirectories ?? []).map { ".headerSearchPath(\(quote($0)))" }
                let settings = searchPaths + [".unsafeFlags([\(list(clangFlags))])"]
                arguments += [
                    "publicHeadersPath: \(quote(Self.publicHeadersDirectory))",
                    "cSettings: [\(settings.joined(separator: ", "))]",
                    "cxxSettings: [\(settings.joined(separator: ", "))]",
                ]
            } else {
                arguments.append("swiftSettings: [.unsafeFlags([\(list(swiftFlags))])]")
            }
            arguments.append("linkerSettings: [\(frameworks.joined(separator: ", "))]")
            return ".target(\n            \(arguments.joined(separator: ",\n            "))\n        )"
        }
        let binaries = binaryTargets.map {
            ".binaryTarget(name: \(quote($0)), path: \(quote("Frameworks/\($0).xcframework")))"
        }

        return """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: \(quote(product.name)),
            platforms: [.iOS("\(ShellPackage.deploymentTarget)")],
            products: [
                .library(name: \(quote(product.name)), type: .dynamic, targets: [\(list(product.targets.map(\.name)))]),
            ],
            targets: [
                \((targets + binaries).joined(separator: ",\n        "))
            ],
            swiftLanguageModes: [.v5],
            cxxLanguageStandard: .cxx20
        )

        """
    }

    /// Public headers live in `<publicHeadersDirectory>/<product>/` so that both `"Header.h"` and
    /// `<Product/Header.h>` imports resolve, as they do in the CocoaPods build.
    static let publicHeadersDirectory = "xtool-public"

    /// The framework's module map. Frameworks that don't link React don't `use` it.
    func frameworkModuleMap(hasHeaders: Bool, swiftHeader: String?) -> String {
        var lines = ["framework module \(product.name) {"]
        if (product.externalDependencies ?? []).contains("React") {
            lines.append("    use React")
        }
        if hasHeaders {
            lines.append("    umbrella header \"\(product.name)_umbrella.h\"")
        }
        if let swiftHeader {
            lines.append("    header \"\(swiftHeader)\"")
        }
        lines += ["", "    export *", "    module * { export * }", "}", ""]
        return lines.joined(separator: "\n")
    }

    /// Imports `headers` by file name, or by absolute path for a module map outside the framework.
    func umbrellaHeader(headers: [URL], absolute: Bool = false) -> String {
        let excluded = Set(product.excludeFromUmbrella ?? [])
        return headers
            .filter { !excluded.contains($0.lastPathComponent) }
            .map { "#import \"\(absolute ? $0.path : $0.lastPathComponent)\"\n" }
            .joined()
    }
}

/// The glob syntax `spm.config.json` patterns use: `*`, `**`, `?` and `{a,b}`.
struct Glob: Sendable {
    private let pattern: String

    init?(_ glob: String) {
        var regex = "^"
        var chars = Array(glob)[...]
        var braces = 0
        while let char = chars.popFirst() {
            switch char {
            case "*" where chars.first == "*":
                chars.removeFirst()
                if chars.first == "/" {
                    chars.removeFirst()
                    regex += "(?:.*/)?"
                } else {
                    regex += ".*"
                }
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            case "{": braces += 1; regex += "(?:"
            case "}" where braces > 0: braces -= 1; regex += ")"
            case "," where braces > 0: regex += "|"
            default: regex += NSRegularExpression.escapedPattern(for: String(char))
            }
        }
        guard braces == 0, (try? NSRegularExpression(pattern: regex + "$")) != nil else { return nil }
        self.pattern = regex + "$"
    }

    func matches(_ path: String) -> Bool {
        path.range(of: pattern, options: .regularExpression) != nil
    }
}

#if !os(macOS)
import Foundation
import PackLib
import Subprocess
import XUtils

struct ExpoLinuxSupport: Sendable {
    var projectRoot: URL
    var appRoot: URL

    private var nodeModules: URL { projectRoot.appendingPathComponent("node_modules") }
    private var precompiled: URL { appRoot.appendingPathComponent("expo-precompiled", isDirectory: true) }

    /// Bump when the layout of the frameworks xtool builds changes, so stale builds are redone.
    private static let prebuildRevision = 1

    func prepare(environment: Environment) async throws -> Environment {
        try await buildMacros()

        let shim = appRoot.appendingPathComponent(".shims/darwin-platform.js")
        try Data("Object.defineProperty(process, 'platform', { value: 'darwin' });\n".utf8).write(to: shim)
        let nodeOptions = [ProcessInfo.processInfo.environment["NODE_OPTIONS"], "--require \(shim.path)"]
            .compactMap { $0 }
            .joined(separator: " ")

        var additions: [Environment.Key: String?] = ["NODE_OPTIONS": nodeOptions]
        try await buildJSI()
        try await buildPrebuilds()
        if FileManager.default.fileExists(atPath: precompiled.path) {
            additions["EXPO_PRECOMPILED_MODULES_PATH"] = precompiled.path
        }
        return environment.updating(additions)
    }

    private func buildMacros() async throws {
        let package = nodeModules.appendingPathComponent("expo-modules-macros/apple")
        let binary = package.appendingPathComponent("ExpoModulesMacros")
        guard FileManager.default.fileExists(atPath: package.path), !Self.isELF(binary) else { return }

        print("Building Expo macros for Linux (first run only, this takes a few minutes)...")
        let work = appRoot.appendingPathComponent("expo-macros", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        for item in ["Package.swift", "Package.resolved", "Sources"] {
            let source = package.appendingPathComponent(item)
            let destination = work.appendingPathComponent(item)
            try? FileManager.default.removeItem(at: destination)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
        let manifest = work.appendingPathComponent("Package.swift")
        let contents = try String(contentsOf: manifest, encoding: .utf8)
        try Data(contents.replacingOccurrences(of: ".macro(", with: ".executableTarget(").utf8).write(to: manifest)

        try await Shell.run(
            ["swift", "build", "-c", "release", "--build-system", "native", "--product", "ExpoModulesMacros"],
            in: work
        )

        let original = package.appendingPathComponent("ExpoModulesMacros.darwin")
        if FileManager.default.fileExists(atPath: original.path) {
            try? FileManager.default.removeItem(at: binary)
        } else {
            try FileManager.default.moveItem(at: binary, to: original)
        }
        try FileManager.default.copyItem(at: work.appendingPathComponent(".build/release/ExpoModulesMacros"), to: binary)
    }

    /// Expo publishes only ExpoModulesJSI's headers and builds the framework in an Xcode build
    /// phase, which xtool doesn't run, so build it here. `ReactNativeProject` links it.
    private func buildJSI() async throws {
        let package = nodeModules.appendingPathComponent("expo-modules-jsi")
        let published = package.appendingPathComponent("prebuilds/output/release/xcframeworks")
        guard FileManager.default.fileExists(atPath: package.path),
              !FileManager.default.fileExists(atPath: published.path)
        else { return }

        let version = try Self.version(of: package)
        let stamp = precompiled.appendingPathComponent("expo-modules-jsi.version")
        if (try? String(contentsOf: stamp, encoding: .utf8)) == version {
            return
        }

        print("Building ExpoModulesJSI \(version), which Expo doesn't publish prebuilt...")
        let work = appRoot.appendingPathComponent("expo-jsi", isDirectory: true)
        let source = work.appendingPathComponent("src", isDirectory: true)
        let pods = work.appendingPathComponent("pods", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: pods.appendingPathComponent("Headers/Public"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package.appendingPathComponent("apple"), to: source)
        try FileManager.default.createSymbolicLink(
            at: pods.appendingPathComponent("Headers/Public/hermes-engine"),
            withDestinationURL: try reactNativeArtifacts().appendingPathComponent("hermes-headers")
        )

        let headerRoots: [Environment.Key: String?] = [
            "PODS_ROOT": pods.path,
            "RN_ROOT": nodeModules.appendingPathComponent("react-native").path,
        ]
        try await Shell.run(["bash", "scripts/generate-modulemap.sh"], in: source, environment: .inherit.updating(headerRoots))

        let include = try await Shell.hostToolchain().appendingPathComponent("include").path
        let buildDir = try await buildFramework(
            "ExpoModulesJSI",
            package: source,
            options: [
                "-Xcc", "-I\(include)", "-Xcxx", "-I\(include)", "-Xswiftc", "-Xcc", "-Xswiftc", "-I\(include)",
                "-Xswiftc", "-enable-experimental-feature", "-Xswiftc", "AssumeResilientCxxTypes",
                "-Xlinker", "-all_load",
            ],
            environment: headerRoots
        )

        let products = buildDir.appendingPathComponent("Products/Release-iphoneos")
        let swiftHeader = buildDir.appendingPathComponent("Intermediates.noindex/GeneratedModuleMaps-iphoneos/ExpoModulesJSI-Swift.h")
        let publicHeaders = source.appendingPathComponent("Sources/ExpoModulesJSI-Cxx/include/Public")
        let cxxHeaders = try FileManager.default.contentsOfDirectory(atPath: publicHeaders.path)
            .filter { $0.hasSuffix(".h") }
            .sorted()
        let moduleMap = """
        module ExpoModulesJSI {
          header "\(swiftHeader.lastPathComponent)"
          export *

          explicit module Cxx {
            requires cplusplus
        \(cxxHeaders.map { "    header \"\($0)\"" }.joined(separator: "\n"))
            export *
          }
        }

        """
        for flavor in ExpoPrebuild.flavors {
            try writeXCFramework(
                named: "ExpoModulesJSI",
                at: ExpoPrebuild.artifactDirectory(in: precompiled, packageName: "expo-modules-jsi", flavor: flavor)
                    .appendingPathComponent("ExpoModulesJSI.xcframework"),
                binary: products.appendingPathComponent("libExpoModulesJSI.dylib"),
                swiftModule: products.appendingPathComponent("ExpoModulesJSI.swiftmodule"),
                headers: [swiftHeader] + cxxHeaders.map { publicHeaders.appendingPathComponent($0) },
                moduleMap: moduleMap
            )
        }
        try Data(version.utf8).write(to: stamp)
    }

    /// Builds every autolinked Expo module that the SwiftPM plugin needs prebuilt but that Expo
    /// doesn't publish prebuilt, from its `spm.config.json`.
    private func buildPrebuilds() async throws {
        let modules = try await autolinkedModules()
        var pending: [ExpoPrebuild] = []
        for prebuild in ExpoPrebuild.discover(modules: modules) {
            if let reason = prebuild.unsupportedReason {
                print("warning: xtool can't prebuild \(prebuild.product.name) (\(prebuild.packageName)): \(reason).")
            } else {
                pending.append(prebuild)
            }
        }

        let roots = Dictionary(modules.map { ($0.packageName, $0.moduleRoot) }) { first, _ in first }
        // Build what other pending products link first.
        while !pending.isEmpty {
            let index = pending.firstIndex { prebuild in
                !prebuild.expoDependencies.contains { dependency in
                    pending.contains { $0.packageName == dependency.packageName && $0.product.name == dependency.product }
                }
            } ?? 0
            try await build(pending.remove(at: index), roots: roots)
        }
    }

    private func autolinkedModules() async throws -> [(packageName: String, moduleRoot: URL)] {
        struct Resolution: Decodable {
            struct Module: Decodable {
                struct Pod: Decodable { var podspecDir: String }
                var packageName: String
                var pods: [Pod]
            }

            var modules: [Module]
        }
        let output = try await Shell.capture(
            ["npx", "expo-modules-autolinking", "resolve", "--platform", "apple", "--json"],
            in: projectRoot
        )
        return try JSONDecoder().decode(Resolution.self, from: output).modules.compactMap { module in
            guard let pod = module.pods.first else { return nil }
            var root = URL(fileURLWithPath: pod.podspecDir, isDirectory: true)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("package.json").path) {
                guard root.path != "/" else { return nil }
                root.deleteLastPathComponent()
            }
            return (module.packageName, root)
        }
    }

    private func build(_ prebuild: ExpoPrebuild, roots: [String: URL]) async throws {
        let name = prebuild.product.name
        let fileManager = FileManager.default
        let version = try Self.version(of: prebuild.moduleRoot)
        let dependencyVersions = try Set(prebuild.expoDependencies.map(\.packageName)).sorted().map { package in
            "\(package) \(try roots[package].map(Self.version) ?? "?")"
        }
        let stampValue = ([version] + dependencyVersions + ["revision \(Self.prebuildRevision)"]).joined(separator: "\n")
        let stamp = precompiled.appendingPathComponent("\(prebuild.packageName)/\(name).version")
        if (try? String(contentsOf: stamp, encoding: .utf8)) == stampValue {
            return
        }

        print("Building \(name) (\(prebuild.packageName) \(version)), which Expo doesn't publish prebuilt...")
        let work = appRoot.appendingPathComponent("expo-prebuilds/\(name)", isDirectory: true)
        try? fileManager.removeItem(at: work)

        let (publicHeaders, resources) = try stageSources(of: prebuild, in: work)
        let (binaryTargets, linkedSwiftFlags, clangFlags) = try await linkDependencies(of: prebuild, roots: roots, in: work)
        var swiftFlags = linkedSwiftFlags

        if prebuild.needsUnderlyingModule {
            let underlying = work.appendingPathComponent("Underlying", isDirectory: true)
            try fileManager.createDirectory(at: underlying, withIntermediateDirectories: true)
            try Data(prebuild.umbrellaHeader(headers: publicHeaders, absolute: true).utf8)
                .write(to: underlying.appendingPathComponent("umbrella.h"))
            try Data("module \(name) {\n  umbrella header \"umbrella.h\"\n  export *\n}\n".utf8)
                .write(to: underlying.appendingPathComponent("module.modulemap"))
            swiftFlags += [
                "-import-underlying-module",
                "-Xcc", "-fmodule-map-file=\(underlying.appendingPathComponent("module.modulemap").path)",
            ]
        }

        try Data(prebuild.manifest(binaryTargets: binaryTargets, swiftFlags: swiftFlags, clangFlags: clangFlags).utf8)
            .write(to: work.appendingPathComponent("Package.swift"))
        let buildDir = try await buildFramework(name, package: work)

        let products = buildDir.appendingPathComponent("Products/Release-iphoneos")
        let swiftHeader = buildDir.appendingPathComponent("Intermediates.noindex/GeneratedModuleMaps-iphoneos/\(name)-Swift.h")
        let hasSwiftHeader = prebuild.swiftTarget != nil && fileManager.fileExists(atPath: swiftHeader.path)
        let swiftModule = products.appendingPathComponent("\(name).swiftmodule")
        let umbrella = work.appendingPathComponent("\(name)_umbrella.h")
        try Data(prebuild.umbrellaHeader(headers: publicHeaders).utf8).write(to: umbrella)

        for flavor in ExpoPrebuild.flavors {
            try writeXCFramework(
                named: name,
                at: ExpoPrebuild.artifactDirectory(in: precompiled, packageName: prebuild.packageName, flavor: flavor)
                    .appendingPathComponent("\(name).xcframework"),
                binary: products.appendingPathComponent("lib\(name).dylib"),
                swiftModule: fileManager.fileExists(atPath: swiftModule.path) ? swiftModule : nil,
                headers: publicHeaders + (publicHeaders.isEmpty ? [] : [umbrella]) + (hasSwiftHeader ? [swiftHeader] : []),
                moduleMap: prebuild.frameworkModuleMap(
                    hasHeaders: !publicHeaders.isEmpty,
                    swiftHeader: hasSwiftHeader ? swiftHeader.lastPathComponent : nil
                ),
                resources: resources
            )
        }
        try Data(stampValue.utf8).write(to: stamp)
    }

    /// Copies each target's sources into `work/Sources/<target>`, with public headers under
    /// `xtool-public/<module>`, and returns the framework's public headers and resources.
    private func stageSources(of prebuild: ExpoPrebuild, in work: URL) throws -> (headers: [URL], resources: [URL]) {
        let name = prebuild.product.name
        let fileManager = FileManager.default
        var publicHeaders: [URL] = []
        var resources: [URL] = []
        for target in prebuild.product.targets {
            let sources = work.appendingPathComponent("Sources/\(target.name)", isDirectory: true)
            let targetRoot = prebuild.moduleRoot.appendingPathComponent(target.path, isDirectory: true)
            let headers = target.isClang
                ? ExpoPrebuild.files(matching: target.headerPattern ?? "**/*.h", in: target, moduleRoot: prebuild.moduleRoot)
                : []
            let files = ExpoPrebuild.files(matching: target.pattern ?? "**/*", in: target, moduleRoot: prebuild.moduleRoot)
            guard !files.isEmpty else {
                throw StringError("\(name): target \(target.name) matches no sources in \(targetRoot.path)")
            }
            for file in Set(files + headers) {
                let destination = sources.appendingPathComponent(file)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: targetRoot.appendingPathComponent(file), to: destination)
            }
            if target.isClang {
                let module = sources
                    .appendingPathComponent(ExpoPrebuild.publicHeadersDirectory)
                    .appendingPathComponent(target.moduleName ?? target.name)
                try fileManager.createDirectory(at: module, withIntermediateDirectories: true)
                for header in headers {
                    let destination = module.appendingPathComponent((header as NSString).lastPathComponent)
                    if !fileManager.fileExists(atPath: destination.path) {
                        try fileManager.copyItem(at: targetRoot.appendingPathComponent(header), to: destination)
                    }
                }
                if target.name == prebuild.headersTarget?.name {
                    publicHeaders = try fileManager.contentsOfDirectory(at: module, includingPropertiesForKeys: nil)
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                }
            }
            resources += (target.resources ?? []).map { prebuild.moduleRoot.appendingPathComponent($0.path) }
        }
        return (publicHeaders, resources)
    }

    /// Links the product's external dependencies into `work/Frameworks` and returns the binary
    /// targets plus the Swift and Clang flags they need.
    private func linkDependencies(
        of prebuild: ExpoPrebuild, roots: [String: URL], in work: URL
    ) async throws -> (binaryTargets: [String], swiftFlags: [String], clangFlags: [String]) {
        let fileManager = FileManager.default
        let frameworks = work.appendingPathComponent("Frameworks", isDirectory: true)
        try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        var binaryTargets: [String] = []
        let link = { (target: String, xcframework: URL) in
            guard !binaryTargets.contains(target) else { return }
            try fileManager.createSymbolicLink(
                at: frameworks.appendingPathComponent("\(target).xcframework"),
                withDestinationURL: xcframework
            )
            binaryTargets.append(target)
        }

        let artifacts = try reactNativeArtifacts()
        var swiftFlags: [String] = []
        var clangFlags: [String] = []
        for dependency in prebuild.product.externalDependencies ?? [] {
            switch dependency {
            case "React":
                try link("React", artifacts.appendingPathComponent("React.xcframework"))
                try link("ReactNativeHeaders", artifacts.appendingPathComponent("ReactNativeHeaders.xcframework"))
            case "ReactNativeDependencies":
                try link("ReactNativeDependencies", artifacts.appendingPathComponent("ReactNativeDependencies.xcframework"))
                try link(
                    "ReactNativeDependenciesHeaders",
                    artifacts.appendingPathComponent("ReactNativeDependenciesHeaders.xcframework")
                )
            case "Hermes":
                try link("hermesvm", artifacts.appendingPathComponent("hermes-engine.xcframework"))
                let headers = artifacts.appendingPathComponent("hermes-headers").path
                clangFlags += ["-I\(headers)"]
                swiftFlags += ["-Xcc", "-I\(headers)"]
            default:
                break
            }
        }
        for dependency in prebuild.expoDependencies {
            let xcframework = try await expoArtifact(dependency.product, of: dependency.packageName, roots: roots, work: work)
            try link(dependency.product, xcframework)
            // ExpoModulesCore's interface re-exports ExpoModulesJSI, which ships as a headers-only XCFramework.
            if dependency.packageName == "expo-modules-core", binaryTargets.contains("ExpoModulesJSIHeaders") == false {
                let headers = try await expoArtifact(
                    "ExpoModulesJSIHeaders", of: "expo-modules-jsi", roots: roots, work: work, flavor: "headers"
                )
                try link("ExpoModulesJSIHeaders", headers)
                swiftFlags += ["-I", headers.appendingPathComponent("ios-arm64").path]
                let macros = nodeModules.appendingPathComponent("expo-modules-macros/apple/ExpoModulesMacros")
                if FileManager.default.fileExists(atPath: macros.path) {
                    swiftFlags += ["-Xfrontend", "-load-plugin-executable", "-Xfrontend", "\(macros.path)#ExpoModulesMacros"]
                }
            }
        }
        return (binaryTargets, swiftFlags, clangFlags)
    }

    /// The Release XCFramework of an Expo product, from an earlier xtool build or else the npm
    /// package. Tarballs are expanded into `work`.
    private func expoArtifact(
        _ product: String, of packageName: String, roots: [String: URL], work: URL, flavor: String = "release"
    ) async throws -> URL {
        let built = ExpoPrebuild.artifactDirectory(in: precompiled, packageName: packageName, flavor: flavor)
        let root = roots[packageName] ?? nodeModules.appendingPathComponent(packageName)
        let bundled = root.appendingPathComponent("prebuilds/output/\(flavor)/xcframeworks")
        guard let artifact = ExpoPrebuild.artifact(named: product, in: built) ?? ExpoPrebuild.artifact(named: product, in: bundled)
        else {
            throw StringError("\(product) (\(packageName)) has no prebuilt XCFramework in \(bundled.path)")
        }
        guard artifact.pathExtension == "gz" else { return artifact }

        let destination = work.appendingPathComponent("Extracted/\(product)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await Shell.run(["tar", "-xzf", artifact.path, "-C", destination.path], in: work)
        return destination.appendingPathComponent("\(product).xcframework")
    }

    /// Builds the dynamic library product `name` of `package` for iOS and returns the build directory.
    private func buildFramework(
        _ name: String, package: URL, options: [String] = [], environment: [Environment.Key: String?] = [:]
    ) async throws -> URL {
        let settings = try await BuildSettings(configuration: .release, triple: "arm64-apple-ios", options: options + [
            "-Xlinker", "-install_name", "-Xlinker", "@rpath/\(name).framework/\(name)",
        ])
        guard settings.buildSystem == .swiftBuild else {
            throw StringError("Building \(name) requires the Swift Build build system (Swift 6.4+)")
        }
        var build = try await settings
            .withPackagePath(package.path)
            .swiftPMInvocation(forTool: "build", arguments: ["--product", name])
        build.environment = build.environment.updating(environment)
        try await Subprocess.run(build, output: .currentStandardOutput, error: .currentStandardError).checkSuccess()
        return package.appendingPathComponent(".build/out")
    }

    private func writeXCFramework(
        named name: String,
        at xcframework: URL,
        binary: URL,
        swiftModule: URL?,
        headers: [URL],
        moduleMap: String,
        resources: [URL] = []
    ) throws {
        let fileManager = FileManager.default
        let framework = xcframework.appendingPathComponent("ios-arm64/\(name).framework", isDirectory: true)
        let headersDir = framework.appendingPathComponent("Headers", isDirectory: true)
        let modules = framework.appendingPathComponent("Modules", isDirectory: true)
        try? fileManager.removeItem(at: xcframework)
        try fileManager.createDirectory(at: headersDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modules, withIntermediateDirectories: true)

        try fileManager.copyItem(at: binary, to: framework.appendingPathComponent(name))
        if let swiftModule {
            try fileManager.copyItem(at: swiftModule, to: modules.appendingPathComponent(swiftModule.lastPathComponent))
        }
        for header in headers {
            try fileManager.copyItem(at: header, to: headersDir.appendingPathComponent(header.lastPathComponent))
        }
        for resource in resources {
            try fileManager.copyItem(at: resource, to: framework.appendingPathComponent(resource.lastPathComponent))
        }
        try Data(moduleMap.utf8).write(to: modules.appendingPathComponent("module.modulemap"))

        try Self.writePlist([
            "CFBundleExecutable": name,
            "CFBundleIdentifier": "dev.expo.\(name)",
            "CFBundleName": name,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "MinimumOSVersion": ShellPackage.deploymentTarget,
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
        ], to: framework.appendingPathComponent("Info.plist"))
        try Self.writePlist([
            "AvailableLibraries": [[
                "BinaryPath": "\(name).framework/\(name)",
                "LibraryIdentifier": "ios-arm64",
                "LibraryPath": "\(name).framework",
                "SupportedArchitectures": ["arm64"],
                "SupportedPlatform": "ios",
            ]],
            "CFBundlePackageType": "XFWK",
            "XCFrameworkFormatVersion": "1.0",
        ], to: xcframework.appendingPathComponent("Info.plist"))
    }

    /// React Native's Release artifacts, which `setup-apple-spm.js download` caches.
    private func reactNativeArtifacts() throws -> URL {
        let version = try Self.version(of: nodeModules.appendingPathComponent("react-native"))
        let artifacts = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ReactNative/spm-artifacts/\(version)/release")
        guard FileManager.default.fileExists(atPath: artifacts.appendingPathComponent("hermes-headers").path) else {
            throw StringError("React Native artifacts not found at \(artifacts.path)")
        }
        return artifacts
    }

    private static func version(of package: URL) throws -> String {
        struct Manifest: Decodable { var version: String }
        let data = try Data(contentsOf: package.appendingPathComponent("package.json"))
        return try JSONDecoder().decode(Manifest.self, from: data).version
    }

    private static func isELF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x7F, 0x45, 0x4C, 0x46])
    }

    private static func writePlist(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }
}
#endif

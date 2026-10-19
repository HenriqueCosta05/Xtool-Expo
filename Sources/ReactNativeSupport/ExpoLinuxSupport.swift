#if !os(macOS)
import Foundation
import PackLib
import Subprocess
import XUtils

struct ExpoLinuxSupport: Sendable {
    var projectRoot: URL
    var appRoot: URL

    private var nodeModules: URL { projectRoot.appendingPathComponent("node_modules") }

    func prepare(environment: Environment) async throws -> Environment {
        try await buildMacros()

        let shim = appRoot.appendingPathComponent(".shims/darwin-platform.js")
        try Data("Object.defineProperty(process, 'platform', { value: 'darwin' });\n".utf8).write(to: shim)
        let nodeOptions = [ProcessInfo.processInfo.environment["NODE_OPTIONS"], "--require \(shim.path)"]
            .compactMap { $0 }
            .joined(separator: " ")

        var additions: [Environment.Key: String?] = ["NODE_OPTIONS": nodeOptions]
        if let precompiled = try await buildJSI() {
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

    private func buildJSI() async throws -> URL? {
        let package = nodeModules.appendingPathComponent("expo-modules-jsi")
        let published = package.appendingPathComponent("prebuilds/output/release/xcframeworks")
        guard FileManager.default.fileExists(atPath: package.path),
              !FileManager.default.fileExists(atPath: published.path)
        else { return nil }

        let output = appRoot.appendingPathComponent("expo-precompiled", isDirectory: true)
        let version = try Self.version(of: package)
        let stamp = output.appendingPathComponent("expo-modules-jsi.version")
        if (try? String(contentsOf: stamp, encoding: .utf8)) == version {
            return output
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
            withDestinationURL: try hermesHeaders()
        )

        let headerRoots: [Environment.Key: String?] = [
            "PODS_ROOT": pods.path,
            "RN_ROOT": nodeModules.appendingPathComponent("react-native").path,
        ]
        try await Shell.run(["bash", "scripts/generate-modulemap.sh"], in: source, environment: .inherit.updating(headerRoots))

        let include = try await Shell.hostToolchain().appendingPathComponent("include").path
        let settings = try await BuildSettings(configuration: .release, triple: "arm64-apple-ios", options: [
            "-Xcc", "-I\(include)", "-Xcxx", "-I\(include)", "-Xswiftc", "-Xcc", "-Xswiftc", "-I\(include)",
            "-Xswiftc", "-enable-experimental-feature", "-Xswiftc", "AssumeResilientCxxTypes",
            "-Xlinker", "-all_load",
            "-Xlinker", "-install_name", "-Xlinker", "@rpath/ExpoModulesJSI.framework/ExpoModulesJSI",
        ])
        guard settings.buildSystem == .swiftBuild else {
            throw StringError("Building ExpoModulesJSI requires the Swift Build build system (Swift 6.4+)")
        }
        var build = try await settings
            .withPackagePath(source.path)
            .swiftPMInvocation(forTool: "build", arguments: ["--product", "ExpoModulesJSI"])
        build.environment = build.environment.updating(headerRoots)
        try await Subprocess.run(build, output: .currentStandardOutput, error: .currentStandardError).checkSuccess()

        let buildDir = source.appendingPathComponent(".build/out")
        let intermediates = buildDir.appendingPathComponent("Intermediates.noindex/GeneratedModuleMaps-iphoneos")
        for flavor in ["debug", "release"] {
            try writeXCFramework(
                at: output.appendingPathComponent("expo-modules-jsi/output/\(flavor)/xcframeworks/ExpoModulesJSI.xcframework"),
                products: buildDir.appendingPathComponent("Products/Release-iphoneos"),
                swiftHeader: intermediates.appendingPathComponent("ExpoModulesJSI-Swift.h"),
                publicHeaders: source.appendingPathComponent("Sources/ExpoModulesJSI-Cxx/include/Public")
            )
        }
        try Data(version.utf8).write(to: stamp)
        return output
    }

    private func writeXCFramework(at xcframework: URL, products: URL, swiftHeader: URL, publicHeaders: URL) throws {
        let fileManager = FileManager.default
        let framework = xcframework.appendingPathComponent("ios-arm64/ExpoModulesJSI.framework", isDirectory: true)
        let headers = framework.appendingPathComponent("Headers", isDirectory: true)
        let modules = framework.appendingPathComponent("Modules", isDirectory: true)
        try? fileManager.removeItem(at: xcframework)
        try fileManager.createDirectory(at: headers, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modules, withIntermediateDirectories: true)

        try fileManager.copyItem(
            at: products.appendingPathComponent("libExpoModulesJSI.dylib"),
            to: framework.appendingPathComponent("ExpoModulesJSI")
        )
        try fileManager.copyItem(
            at: products.appendingPathComponent("ExpoModulesJSI.swiftmodule"),
            to: modules.appendingPathComponent("ExpoModulesJSI.swiftmodule")
        )
        try fileManager.copyItem(at: swiftHeader, to: headers.appendingPathComponent(swiftHeader.lastPathComponent))

        let cxxHeaders = try fileManager.contentsOfDirectory(atPath: publicHeaders.path).filter { $0.hasSuffix(".h") }.sorted()
        for header in cxxHeaders {
            try fileManager.copyItem(at: publicHeaders.appendingPathComponent(header), to: headers.appendingPathComponent(header))
        }
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
        try Data(moduleMap.utf8).write(to: headers.appendingPathComponent("module.modulemap"))

        try Self.writePlist([
            "CFBundleExecutable": "ExpoModulesJSI",
            "CFBundleIdentifier": "dev.expo.ExpoModulesJSI",
            "CFBundleName": "ExpoModulesJSI",
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "MinimumOSVersion": ShellPackage.deploymentTarget,
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
        ], to: framework.appendingPathComponent("Info.plist"))
        try Self.writePlist([
            "AvailableLibraries": [[
                "BinaryPath": "ExpoModulesJSI.framework/ExpoModulesJSI",
                "LibraryIdentifier": "ios-arm64",
                "LibraryPath": "ExpoModulesJSI.framework",
                "SupportedArchitectures": ["arm64"],
                "SupportedPlatform": "ios",
            ]],
            "CFBundlePackageType": "XFWK",
            "XCFrameworkFormatVersion": "1.0",
        ], to: xcframework.appendingPathComponent("Info.plist"))
    }

    private func hermesHeaders() throws -> URL {
        let version = try Self.version(of: nodeModules.appendingPathComponent("react-native"))
        let headers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ReactNative/spm-artifacts/\(version)/release/hermes-headers")
        guard FileManager.default.fileExists(atPath: headers.path) else {
            throw StringError("Hermes headers not found at \(headers.path)")
        }
        return headers
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

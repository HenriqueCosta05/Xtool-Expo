import Foundation
import PackLib
import Subprocess
import XUtils

enum Shell {
    static func run(_ command: [String], in directory: URL, environment: Environment = .inherit) async throws {
        try await Subprocess.run(
            .name(command[0]),
            arguments: .init(Array(command.dropFirst())),
            environment: environment,
            workingDirectory: FilePath(directory.path),
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()
    }

    static func capture(_ command: [String], in directory: URL, environment: Environment = .inherit) async throws -> Data {
        let result = try await Subprocess.run(
            .name(command[0]),
            arguments: .init(Array(command.dropFirst())),
            environment: environment,
            workingDirectory: FilePath(directory.path),
            output: .data(limit: .max),
            error: .currentStandardError,
        )
        .checkSuccess()
        return result.standardOutput
    }

    static func hostToolchain() async throws -> URL {
        let info = try await capture(["swiftc", "-print-target-info"], in: FileManager.default.temporaryDirectory)
        let paths = (try JSONSerialization.jsonObject(with: info) as? [String: Any])?["paths"] as? [String: Any]
        guard let resourcePath = paths?["runtimeResourcePath"] as? String else {
            throw StringError("Could not locate the Swift toolchain")
        }
        return URL(fileURLWithPath: resourcePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

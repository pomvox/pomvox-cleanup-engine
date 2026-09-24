import Foundation
import CryptoKit
import CleanupCore
import Darwin

public struct PackManifest: Codable, Sendable {
    public struct Artifact: Codable, Sendable {
        public let path: String
        public let bytes: Int
        public let sha256: String
    }
    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let publisher: String
    public let license: String
    public let licenseURL: String
    public let modelID: String
    public let modelRevision: String
    public let runtime: String
    public let prompt: String
    public let quantization: String
    public let languages: [String]
    public let capabilities: [String]
    public let rules: [String]
    public let artifacts: [Artifact]
    public let limitations: [String]
    public let evidence: String
}

public struct ValidatedPack: Sendable {
    public let directory: URL
    public let manifest: PackManifest
    public let digest: String
    let fileIdentity: [String: String]
}

public enum PackLoader {
    public static let runtimeVersion = "mlx-swift-lm-3.31.4"

    /// Installed, caller-owned directory only. No network access or executable pack code.
    public static func validate(directory: URL) throws -> ValidatedPack {
        guard directory.isFileURL else { throw CleanupError.invalidPack("a local directory is required") }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let identity = try fileIdentity(root)
        let manifestURL = root.appendingPathComponent("pack.json")
        var data = Data()
        try readRegularFile(manifestURL, limit: 65_536) { data.append($0) }
        let keys: Set<String> = ["schemaVersion", "id", "version", "publisher", "license", "licenseURL",
            "modelID", "modelRevision", "runtime", "prompt", "quantization", "languages", "capabilities",
            "rules", "artifacts", "limitations", "evidence"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys,
              let artifacts = object["artifacts"] as? [[String: Any]],
              artifacts.allSatisfy({ Set($0.keys) == ["path", "bytes", "sha256"] }) else {
            throw CleanupError.invalidPack("unknown or missing manifest field")
        }
        let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.runtime == runtimeVersion,
              manifest.prompt == "simplewords-frozen-v2", manifest.quantization == "8bit",
              manifest.rules == [CleanupLogic.rulesVersion],
              manifest.capabilities == ["vocabulary"], manifest.languages == ["en"] else {
            throw CleanupError.incompatible("unsupported schema, runtime, prompt, settings, rules, or language")
        }
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        guard matches(manifest.id, #"^[a-z0-9][a-z0-9.-]{0,63}$"#),
              matches(manifest.version, #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[a-z0-9]+(\.[a-z0-9]+)*)?$"#),
              matches(manifest.modelRevision, #"^[a-f0-9]{40}$"#),
              !manifest.publisher.isEmpty, !manifest.license.isEmpty,
              !manifest.evidence.isEmpty, !manifest.limitations.isEmpty,
              manifest.artifacts.count == 7 else {
            throw CleanupError.invalidPack("missing identity, immutable revision, evidence, or artifacts")
        }
        // Fixed preview layout prevents extra weights, adapters, tokenizer references and plugins.
        let allowed: Set<String> = ["config.json", "tokenizer.json", "tokenizer_config.json",
            "chat_template.jinja", "model.safetensors", "model.safetensors.index.json", "system_v2.txt"]
        guard Set(manifest.artifacts.map(\.path)) == allowed else {
            throw CleanupError.invalidPack("artifact paths must match the supported flat layout")
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard Set(contents).isSubset(of: allowed.union(["pack.json"])) else {
            throw CleanupError.invalidPack("unexpected file or directory in pack")
        }
        var verifiedMetadata: [String: Data] = [:]
        let metadata: Set<String> = ["model.safetensors.index.json", "tokenizer_config.json", "system_v2.txt"]
        for artifact in manifest.artifacts {
            let url = root.appendingPathComponent(artifact.path)
            let limit = artifact.path == "model.safetensors" ? 4_000_000_000 : 32_000_000
            guard artifact.bytes > 0, artifact.bytes <= limit,
                  matches(artifact.sha256, #"^[a-f0-9]{64}$"#) else {
                throw CleanupError.invalidPack("invalid size or file type: \(artifact.path)")
            }
            var digest = SHA256()
            var captured = Data()
            try readRegularFile(url, limit: artifact.bytes, expectedSize: artifact.bytes) { chunk in
                digest.update(data: chunk)
                if metadata.contains(artifact.path) { captured.append(chunk) }
            }
            guard hex(digest.finalize()) == artifact.sha256 else {
                throw CleanupError.invalidPack("checksum mismatch: \(artifact.path)")
            }
            if metadata.contains(artifact.path) { verifiedMetadata[artifact.path] = captured }
        }
        // The model index must not direct loading outside the verified flat file set.
        let index = try JSONSerialization.jsonObject(with: verifiedMetadata["model.safetensors.index.json"]!) as? [String: Any]
        guard let weightMap = index?["weight_map"] as? [String: String], !weightMap.isEmpty,
              weightMap.values.allSatisfy({ $0 == "model.safetensors" }) else {
            throw CleanupError.invalidPack("unsupported weight index")
        }
        guard let config = try JSONSerialization.jsonObject(with: verifiedMetadata["tokenizer_config.json"]!) as? [String: Any],
              config["auto_map"] == nil else { throw CleanupError.invalidPack("custom tokenizer code is unsupported") }
        guard let prompt = String(data: verifiedMetadata["system_v2.txt"]!, encoding: .utf8),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CleanupError.invalidPack("empty frozen prompt")
        }
        guard try fileIdentity(root) == identity else { throw CleanupError.invalidPack("pack changed during validation") }
        return ValidatedPack(directory: root, manifest: manifest,
                             digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), fileIdentity: identity)
    }

    /// Process-local reuse only. Changed files require a fresh full validation.
    /// This relies on the same caller-owned, immutable filesystem trust boundary as open.
    public static func revalidate(_ pack: ValidatedPack) throws -> ValidatedPack {
        try Task.checkCancellation()
        guard try fileIdentity(pack.directory) == pack.fileIdentity else {
            throw CleanupError.invalidPack("validated pack changed; perform a fresh validation")
        }
        return pack
    }

    static func fileIdentity(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            var value = stat()
            guard lstat(root.appendingPathComponent(name).path, &value) == 0,
                  (value.st_mode & S_IFMT) == S_IFREG else {
                throw CleanupError.invalidPack("pack must contain regular files")
            }
            result[name] = "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_size):"
                + "\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):"
                + "\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
        }
        return result
    }

    public static func hash(_ url: URL) throws -> String {
        var digest = SHA256()
        try readRegularFile(url, limit: 4_000_000_000) { digest.update(data: $0) }
        return hex(digest.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Inspect the opened descriptor, not a path that could change before opening.
    /// Nonblocking open prevents FIFOs from hanging preparation before fstat rejects them.
    private static func readRegularFile(_ url: URL, limit: Int, expectedSize: Int? = nil,
                                        consume: (Data) -> Void) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CleanupError.invalidPack("a local file is required") }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw CleanupError.invalidPack("cannot open regular file: \(url.lastPathComponent)") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= limit,
              expectedSize.map({ before.st_size == $0 }) ?? true else {
            throw CleanupError.invalidPack("invalid size or file type: \(url.lastPathComponent)")
        }
        var bytes = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: min(1_048_576, limit - bytes + 1)), !chunk.isEmpty else { break }
            bytes += chunk.count
            guard bytes <= limit else { throw CleanupError.invalidPack("file grew during validation") }
            consume(chunk)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, bytes == before.st_size,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw CleanupError.invalidPack("file changed during validation")
        }
    }
}

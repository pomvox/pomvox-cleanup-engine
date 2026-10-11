import CleanupPacks
import CryptoKit
import Darwin
import Foundation

/// An installed diarizer pack: `pack.json` plus the compiled Core ML bundles
/// a diarization runtime loads, every file pinned by size and SHA-256.
public struct DiarizerPackManifest: Codable, Sendable {
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
    public let pipeline: String
    /// Who to credit when distributing, as the license requires.
    public let attribution: [String]
    public let artifacts: [Artifact]
    public let limitations: [String]
    public let evidence: String
}

public struct ValidatedDiarizerPack: Sendable {
    public let directory: URL
    public let manifest: DiarizerPackManifest
    /// SHA-256 of the exact manifest bytes; covers every artifact digest.
    public let digest: String
    let fileIdentity: [String: String]

    /// The directory a runtime loads from: it contains the models folder.
    public var modelsDirectory: URL { directory }
}

/// Validates an installed diarizer pack. Same trust model as `PackLoader`:
/// a caller-owned, immutable directory, hash-checked, never downloaded.
public enum DiarizerPackLoader {
    /// The FluidAudio release whose offline pipeline these bundles are compiled for.
    public static let runtimeVersion = "fluidaudio-0.15.5"
    public static let pipeline = "pyannote-community-1-offline"
    /// The folder name the runtime's loader expects under the pack directory.
    public static let modelsFolder = "speaker-diarization"

    static let bundles = ["Segmentation", "FBank", "Embedding", "PldaRho"]
    static let bundleFiles = ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"]

    /// The exact artifact set a pack must declare and contain.
    public static let artifactPaths: Set<String> = {
        var paths = Set(bundles.flatMap { bundle in bundleFiles.map { "\(modelsFolder)/\(bundle).mlmodelc/\($0)" } })
        paths.formUnion(["plda-parameters.json", "LICENSE", "NOTICE.md"].map { "\(modelsFolder)/\($0)" })
        return paths
    }()

    public static func validate(directory: URL) throws -> ValidatedDiarizerPack {
        guard directory.isFileURL else { throw CleanupError.invalidPack("a local directory is required") }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let identity = try fileIdentity(root)
        var data = Data()
        try PackLoader.readRegularFile(root.appendingPathComponent("pack.json"), limit: 65_536) { data.append($0) }
        let keys: Set<String> = ["schemaVersion", "id", "version", "publisher", "license", "licenseURL",
            "modelID", "modelRevision", "runtime", "pipeline", "attribution", "artifacts", "limitations", "evidence"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schemaVersion"] as? Int, schema == 1,
              Set(object.keys) == keys,
              let artifacts = object["artifacts"] as? [[String: Any]],
              artifacts.allSatisfy({ Set($0.keys) == ["path", "bytes", "sha256"] }) else {
            throw CleanupError.invalidPack("unknown or missing manifest field")
        }
        let manifest = try JSONDecoder().decode(DiarizerPackManifest.self, from: data)
        guard manifest.runtime == runtimeVersion, manifest.pipeline == pipeline else {
            throw CleanupError.incompatible("unsupported diarizer runtime or pipeline")
        }
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        guard matches(manifest.id, #"^[a-z0-9][a-z0-9.-]{0,63}$"#),
              matches(manifest.version, #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[a-z0-9]+(\.[a-z0-9]+)*)?$"#),
              matches(manifest.modelRevision, #"^[a-f0-9]{40}$"#),
              !manifest.publisher.isEmpty, !manifest.license.isEmpty, !manifest.attribution.isEmpty,
              !manifest.evidence.isEmpty, !manifest.limitations.isEmpty else {
            throw CleanupError.invalidPack("missing identity, immutable revision, attribution, evidence, or limitations")
        }
        let declared = manifest.artifacts.map(\.path)
        guard Set(declared) == artifactPaths, declared.count == artifactPaths.count else {
            throw CleanupError.invalidPack("artifact paths must match the supported diarizer layout")
        }
        // Every regular file in the tree is a declared artifact or pack.json; nothing else is allowed.
        guard Set(identity.keys) == artifactPaths.union(["pack.json"]) else {
            throw CleanupError.invalidPack("unexpected file or directory in pack")
        }
        for artifact in manifest.artifacts {
            guard artifact.bytes > 0, artifact.bytes <= 100_000_000, matches(artifact.sha256, #"^[a-f0-9]{64}$"#),
                  !artifact.path.contains(".."), !artifact.path.hasPrefix("/") else {
                throw CleanupError.invalidPack("invalid size or path: \(artifact.path)")
            }
            let url = root.appendingPathComponent(artifact.path)
            var digest = SHA256()
            var bytes = 0
            try PackLoader.readRegularFile(url, limit: artifact.bytes, expectedSize: artifact.bytes) { chunk in
                digest.update(data: chunk); bytes += chunk.count
            }
            guard bytes == artifact.bytes,
                  digest.finalize().map({ String(format: "%02x", $0) }).joined() == artifact.sha256 else {
                throw CleanupError.invalidPack("checksum mismatch: \(artifact.path)")
            }
        }
        guard try fileIdentity(root) == identity else { throw CleanupError.invalidPack("pack changed during validation") }
        return ValidatedDiarizerPack(directory: root, manifest: manifest,
            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), fileIdentity: identity)
    }

    /// Process-local reuse only; changed files require a fresh full validation.
    public static func revalidate(_ pack: ValidatedDiarizerPack) throws -> ValidatedDiarizerPack {
        try Task.checkCancellation()
        guard try fileIdentity(pack.directory) == pack.fileIdentity else {
            throw CleanupError.invalidPack("validated diarizer pack changed; perform a fresh validation")
        }
        return pack
    }

    /// Every entry under the root, recursively: regular files keyed by relative
    /// path with their stat identity. Symlinks and special files are refused;
    /// directories are allowed only where an artifact path needs them.
    static func fileIdentity(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let allowedDirectories = Set(artifactPaths.flatMap { path -> [String] in
            let parts = path.split(separator: "/").dropLast()
            return (1...max(1, parts.count)).compactMap { parts.count >= $0 ? parts.prefix($0).joined(separator: "/") : nil }
        })
        func walk(_ relative: String) throws {
            let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let path = relative.isEmpty ? name : relative + "/" + name
                var value = stat()
                guard lstat(root.appendingPathComponent(path).path, &value) == 0 else {
                    throw CleanupError.invalidPack("cannot inspect \(path)")
                }
                switch value.st_mode & S_IFMT {
                case S_IFREG:
                    result[path] = "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_size):"
                        + "\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):"
                        + "\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
                case S_IFDIR:
                    guard allowedDirectories.contains(path) else { throw CleanupError.invalidPack("unexpected directory \(path)") }
                    try walk(path)
                default:
                    throw CleanupError.invalidPack("pack must contain regular files: \(path)")
                }
            }
        }
        try walk("")
        return result
    }
}

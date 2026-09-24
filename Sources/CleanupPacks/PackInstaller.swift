import Foundation
import Darwin
import CleanupCore

/// Installs caller-provided, immutable local snapshots; never downloads assets.
public enum PackInstaller {
    /// Source symlinks are resolved into independent regular destination files. APFS clones
    /// share storage until modified, without tying the installed pack to a cache symlink.
    /// Run off the main actor. Cancellation removes only this invocation's staging directory.
    public static func install(snapshot: URL, manifestData: Data, destination: URL) throws -> ValidatedPack {
        guard snapshot.isFileURL, destination.isFileURL, manifestData.count <= 65_536 else {
            throw CleanupError.invalidPack("local paths and a bounded manifest are required")
        }
        let manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
        let allowed: Set<String> = ["config.json", "tokenizer.json", "tokenizer_config.json",
            "chat_template.jinja", "model.safetensors", "model.safetensors.index.json", "system_v2.txt"]
        guard manifest.artifacts.count == allowed.count, Set(manifest.artifacts.map(\.path)) == allowed else {
            throw CleanupError.invalidPack("unsupported installation layout")
        }
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".pomvox-install-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        for artifact in manifest.artifacts {
            try Task.checkCancellation()
            let source = snapshot.appendingPathComponent(artifact.path).resolvingSymlinksInPath()
            let target = stage.appendingPathComponent(artifact.path)
            var info = stat()
            guard lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  artifact.bytes > 0, artifact.bytes <= (artifact.path == "model.safetensors" ? 4_000_000_000 : 32_000_000),
                  info.st_size == artifact.bytes else {
                throw CleanupError.invalidPack("invalid source size or type: \(artifact.path)")
            }
            // Clone where supported; cross-volume/non-APFS installs use a regular copy.
            if clonefile(source.path, target.path, 0) != 0 {
                try manager.copyItem(at: source, to: target)
            }
        }
        try manifestData.write(to: stage.appendingPathComponent("pack.json"), options: .withoutOverwriting)
        let verified = try PackLoader.validate(directory: stage)
        try Task.checkCancellation()
        // Atomic, exclusive publish: even an empty destination belongs to somebody else.
        guard renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw CleanupError.invalidPack("destination exists or installation could not be published")
        }
        return ValidatedPack(directory: destination.standardizedFileURL.resolvingSymlinksInPath(),
            manifest: verified.manifest, digest: verified.digest, fileIdentity: verified.fileIdentity)
    }
}

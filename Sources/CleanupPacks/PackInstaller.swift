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

/// A published pack directory as listed; its manifest was decoded, its artifacts were not verified.
public struct InstalledPack: Sendable, Equatable {
    public let directory: URL
    public let id: String
    public let version: String
    /// Allocated blocks of every file, what `du` reports. An APFS clone counts in full.
    public let allocatedBytes: Int64
    /// Bytes no other file shares through APFS cloning: what removing the pack frees now.
    /// Equals `allocatedBytes` where the volume cannot say.
    public let privateBytes: Int64
    /// When the manifest was published, the last step of an installation.
    public let installedAt: Date
    /// Device and inode of the directory, so removal never deletes a replacement at the same path.
    let identity: String
}

extension PackInstaller {
    /// Lists the pack directories under `directory`, the parent that `install` publishes into.
    /// A missing parent lists nothing. Hidden entries (staging, removal) and directories without a
    /// decodable manifest are skipped. `Cleaner.open` still verifies every artifact.
    public static func installed(at directory: URL) throws -> [InstalledPack] {
        guard directory.isFileURL else { throw CleanupError.invalidPack("a local directory is required") }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw CleanupError.invalidPack("pack root must be a directory") }
        var packs: [InstalledPack] = []
        for name in try manager.contentsOfDirectory(atPath: root.path).sorted() where !name.hasPrefix(".") {
            let candidate = root.appendingPathComponent(name)
            var info = stat()
            guard lstat(candidate.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            var data = Data()
            guard (try? PackLoader.readRegularFile(candidate.appendingPathComponent("pack.json"), limit: 65_536) { data.append($0) }) != nil,
                  let manifest = try? JSONDecoder().decode(PackManifest.self, from: data) else { continue }
            // Gone since the parent was listed (a concurrent remove) means not installed.
            guard let entries = try? manager.contentsOfDirectory(atPath: candidate.path) else { continue }
            var allocated: Int64 = 0, unshared: Int64 = 0, published = timespec()
            for entry in entries {
                let path = candidate.appendingPathComponent(entry).path
                var file = stat()
                guard lstat(path, &file) == 0, (file.st_mode & S_IFMT) == S_IFREG else { continue }
                let blocks = Int64(file.st_blocks) * 512
                allocated += blocks
                unshared += privateSize(path) ?? blocks
                if entry == "pack.json" { published = file.st_mtimespec }
            }
            packs.append(InstalledPack(directory: candidate, id: manifest.id, version: manifest.version,
                allocatedBytes: allocated, privateBytes: unshared,
                installedAt: Date(timeIntervalSince1970: Double(published.tv_sec) + Double(published.tv_nsec) / 1e9),
                identity: "\(info.st_dev):\(info.st_ino)"))
        }
        return packs
    }

    /// Removes a listed pack. Refuses while a `Cleaner` in this process holds the directory; another
    /// process is not detected, though macOS keeps mapped weights alive until that process is done.
    /// The directory is renamed aside under the hold check and deleted afterwards, so the published
    /// path never holds a partial pack and a concurrent `install` of the same id sees it occupied or free.
    public static func remove(_ pack: InstalledPack) throws {
        let aside = pack.directory.deletingLastPathComponent().appendingPathComponent(".pomvox-remove-" + UUID().uuidString)
        try OpenPacks.shared.whileUnheld(pack.directory) {
            var info = stat()
            guard lstat(pack.directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  "\(info.st_dev):\(info.st_ino)" == pack.identity else {
                throw CleanupError.invalidPack("the listed pack is no longer installed at \(pack.directory.lastPathComponent)")
            }
            guard rename(pack.directory.path, aside.path) == 0 else {
                throw CleanupError.invalidPack("pack could not be removed: \(String(cString: strerror(errno)))")
            }
        }
        try FileManager.default.removeItem(at: aside)
    }

    /// `ATTR_CMNEXT_PRIVATESIZE`: bytes not shared with any clone. Nil where the volume lacks it.
    private static func privateSize(_ path: String) -> Int64? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 16)
        let status = buffer.withUnsafeMutableBytes {
            getattrlist(path, &attributes, $0.baseAddress, 16, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0, buffer.withUnsafeBytes({ $0.load(as: UInt32.self) }) >= 12 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }
}

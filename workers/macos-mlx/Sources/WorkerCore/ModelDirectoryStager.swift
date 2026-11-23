import CryptoKit
import Foundation

/// Stages read-only or cache-managed model directories into a temporary mirror
/// folder whenever `tokenizer.json` must be synthesized from `vocab.json` + `merges.txt`,
/// keeping the user's original HuggingFace snapshot directory untouched.
/// Subdirectories (such as Qwen3-TTS `speech_tokenizer/`) are mirrored as real directories
/// so `FileManager.contentsOfDirectory` and `isDirectory` checks never treat symlinks as non-dirs.
public enum ModelDirectoryStager {
    public static func stageIfMissingTokenizerJSON(_ modelDir: URL) throws -> URL {
        let fm = FileManager.default
        let tokenizerJSON = modelDir.appendingPathComponent("tokenizer.json")
        if fm.fileExists(atPath: tokenizerJSON.path) {
            return modelDir
        }

        let vocab = modelDir.appendingPathComponent("vocab.json")
        let merges = modelDir.appendingPathComponent("merges.txt")
        guard fm.fileExists(atPath: vocab.path), fm.fileExists(atPath: merges.path) else {
            return modelDir
        }

        let digest = SHA256.hash(data: Data(modelDir.path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let stageDir = fm.temporaryDirectory
            .appendingPathComponent("acpm-model-stage-\(digest)", isDirectory: true)
        try mirrorDirectory(from: modelDir, to: stageDir, fileManager: fm)
        return stageDir
    }

    private static func mirrorDirectory(
        from sourceDir: URL,
        to targetDir: URL,
        fileManager fm: FileManager
    ) throws {
        var isTargetDir: ObjCBool = false
        if fm.fileExists(atPath: targetDir.path, isDirectory: &isTargetDir) {
            let attrs = try? fm.attributesOfItem(atPath: targetDir.path)
            let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            if isSymlink || !isTargetDir.boolValue {
                try fm.removeItem(at: targetDir)
                try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }
        } else {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let entries = try fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let resolved = entry.resolvingSymlinksInPath()
            var isSubdir: ObjCBool = false
            _ = fm.fileExists(atPath: resolved.path, isDirectory: &isSubdir)
            let dst = targetDir.appendingPathComponent(entry.lastPathComponent)

            if isSubdir.boolValue {
                try mirrorDirectory(from: resolved, to: dst, fileManager: fm)
            } else {
                if let attrs = try? fm.attributesOfItem(atPath: dst.path),
                   (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
                {
                    continue
                }
                if fm.fileExists(atPath: dst.path) {
                    continue
                }
                try fm.createSymbolicLink(at: dst, withDestinationURL: resolved)
            }
        }
    }
}

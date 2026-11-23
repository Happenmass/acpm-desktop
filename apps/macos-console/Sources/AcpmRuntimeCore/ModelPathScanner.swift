import Foundation

public struct DetectedLocalModel: Identifiable, Sendable, Equatable {
    public var id: String { modelId }
    public let modelId: String
    public let displayName: String
    public let capability: String
    public let path: String
    public let detectedQuant: String?
    public let sourceLabel: String

    public init(
        modelId: String,
        displayName: String,
        capability: String,
        path: String,
        detectedQuant: String? = nil,
        sourceLabel: String
    ) {
        self.modelId = modelId
        self.displayName = displayName
        self.capability = capability
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.detectedQuant = detectedQuant
        self.sourceLabel = sourceLabel
    }
}

public enum ModelPathScanner {
    public static func detectQuant(in directory: URL) -> String? {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let quant = json["quantization"] as? [String: Any],
           let bits = quant["bits"] as? Int
        {
            return "\(bits)bit"
        }

        if let dtype = json["torch_dtype"] as? String {
            switch dtype.lowercased() {
            case "bfloat16", "bf16":
                return "bf16"
            case "float16", "fp16":
                return "fp16"
            default:
                break
            }
        }
        return nil
    }

    public static func isValidModelDirectory(_ directory: URL, capability: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        if capability == "vad" {
            let seg = directory.appendingPathComponent("segmentation.onnx").path
            let mod = directory.appendingPathComponent("model.onnx").path
            return fm.fileExists(atPath: seg) || fm.fileExists(atPath: mod)
        }

        let configPath = directory.appendingPathComponent("config.json").path
        guard fm.fileExists(atPath: configPath),
              let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return false
        }
        return entries.contains { $0.pathExtension.lowercased() == "safetensors" }
    }

    private static func isMlxRepository(_ repoOrSnapDir: URL) -> Bool {
        let nameLower = repoOrSnapDir.path.lowercased()
        if nameLower.contains("mlx") {
            return true
        }
        let cfgURL = repoOrSnapDir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: cfgURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["quantization"] != nil
        {
            return true
        }
        return false
    }

    public static func scanDefaultLocations(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleResourcesURL: URL? = Bundle.main.resourceURL
    ) -> [DetectedLocalModel] {
        var found: [DetectedLocalModel] = []
        let hfHubRoot = homeDirectory.appendingPathComponent(".cache/huggingface/hub")
        let hfLocalRoot = homeDirectory.appendingPathComponent(".cache/huggingface/local-models")
        let codexYanmoRoot = homeDirectory.appendingPathComponent(".cache/codex/models/yanmo-polish")

        // 1. yanmo-correct-4b-cot (LLM) — prioritize standard HF Hub repo, never match 9B
        if let dir = findHuggingFaceSnapshot(
            hubRoot: hfHubRoot,
            folderKeywords: ["yanmo-correct-4b-cot"],
            excludeKeywords: ["9b"],
            capability: "llm",
            requireMlxHint: true
        ) ?? findFirstValidDirectory(
            roots: [codexYanmoRoot, hfLocalRoot],
            leafKeywords: ["4b"],
            excludeLeafKeywords: ["9b"],
            capability: "llm",
            maxDepth: 3
        ) ?? findHuggingFaceSnapshot(
            hubRoot: hfHubRoot,
            folderKeywords: ["qwen", "4b"],
            excludeKeywords: ["9b"],
            capability: "llm",
            requireMlxHint: true
        ) {
            let fromHF = dir.path.contains("/huggingface/hub/")
            found.append(DetectedLocalModel(
                modelId: "yanmo-correct-4b-cot",
                displayName: "Yanmo 4B CoT 后纠错",
                capability: "llm",
                path: dir.path,
                detectedQuant: detectQuant(in: dir),
                sourceLabel: fromHF ? "HuggingFace 标准缓存" : "本地磁盘缓存"
            ))
        }

        // 2. yanmo-correct-9b-cot (LLM)
        if let dir = findHuggingFaceSnapshot(
            hubRoot: hfHubRoot,
            folderKeywords: ["yanmo-correct-9b-cot"],
            capability: "llm",
            requireMlxHint: true
        ) ?? findFirstValidDirectory(
            roots: [codexYanmoRoot, hfLocalRoot],
            leafKeywords: ["9b"],
            capability: "llm",
            maxDepth: 3
        ) {
            let fromHF = dir.path.contains("/huggingface/hub/")
            found.append(DetectedLocalModel(
                modelId: "yanmo-correct-9b-cot",
                displayName: "Yanmo 9B CoT 后纠错",
                capability: "llm",
                path: dir.path,
                detectedQuant: detectQuant(in: dir),
                sourceLabel: fromHF ? "HuggingFace 标准缓存" : "本地磁盘缓存"
            ))
        }

        // 3. qwen3-asr-1.7b
        if let dir = findHuggingFaceSnapshot(
            hubRoot: hfHubRoot,
            folderKeywords: ["qwen3-asr-1.7b"],
            capability: "asr",
            requireMlxHint: true
        ) ?? findFirstValidDirectory(
            roots: [hfLocalRoot],
            leafKeywords: ["qwen3-asr-1.7b"],
            capability: "asr",
            maxDepth: 3
        ) {
            found.append(DetectedLocalModel(
                modelId: "qwen3-asr-1.7b",
                displayName: "Qwen3-ASR 1.7B",
                capability: "asr",
                path: dir.path,
                detectedQuant: detectQuant(in: dir),
                sourceLabel: "HuggingFace 标准缓存"
            ))
        }

        // 4. qwen3-asr-0.6b (skip non-MLX -hf PyTorch snapshots unless MLX quantized)
        if let dir = findHuggingFaceSnapshot(
            hubRoot: hfHubRoot,
            folderKeywords: ["qwen3-asr-0.6b"],
            capability: "asr",
            requireMlxHint: true
        ) ?? findFirstValidDirectory(
            roots: [hfLocalRoot],
            leafKeywords: ["qwen3-asr-0.6b"],
            capability: "asr",
            maxDepth: 3
        ) {
            found.append(DetectedLocalModel(
                modelId: "qwen3-asr-0.6b",
                displayName: "Qwen3-ASR 0.6B (输入法快载版)",
                capability: "asr",
                path: dir.path,
                detectedQuant: detectQuant(in: dir),
                sourceLabel: "HuggingFace 标准缓存"
            ))
        }

        // 5. qwen3-tts-1.7b (prefer Base over CustomVoice/VoiceDesign for voice cloning)
        if let dir = findFirstValidDirectory(
            roots: [hfLocalRoot],
            leafKeywords: ["qwen3-tts", "1.7b", "base"],
            capability: "tts",
            maxDepth: 3
        ) ?? findHuggingFaceSnapshot(
            hubRoot: hfHubRoot,
            folderKeywords: ["qwen3-tts", "1.7b", "base"],
            capability: "tts",
            requireMlxHint: false
        ) ?? findFirstValidDirectory(
            roots: [hfLocalRoot],
            leafKeywords: ["qwen3-tts", "1.7b"],
            capability: "tts",
            maxDepth: 3
        ) ?? findHuggingFaceSnapshot(
            hubRoot: hfHubRoot,
            folderKeywords: ["qwen3-tts", "1.7b"],
            capability: "tts",
            requireMlxHint: false
        ) {
            found.append(DetectedLocalModel(
                modelId: "qwen3-tts-1.7b",
                displayName: "Qwen3-TTS 1.7B 音色克隆",
                capability: "tts",
                path: dir.path,
                detectedQuant: detectQuant(in: dir),
                sourceLabel: "本地 TTS 模型库"
            ))
        }

        // 6. speech-vad-pyannote
        if let resURL = bundleResourcesURL {
            let bundledVad = resURL.appendingPathComponent("models/speech-vad-pyannote")
            if isValidModelDirectory(bundledVad, capability: "vad") {
                found.append(DetectedLocalModel(
                    modelId: "speech-vad-pyannote",
                    displayName: "Pyannote 3.0 CPU VAD",
                    capability: "vad",
                    path: bundledVad.path,
                    detectedQuant: "onnx",
                    sourceLabel: "随应用内置 (开箱即用)"
                ))
            }
        }
        if !found.contains(where: { $0.modelId == "speech-vad-pyannote" }) {
            let cachedVad = homeDirectory.appendingPathComponent(
                ".cache/codex/models/sherpa-onnx/sherpa-onnx-pyannote-segmentation-3-0"
            )
            if isValidModelDirectory(cachedVad, capability: "vad") {
                found.append(DetectedLocalModel(
                    modelId: "speech-vad-pyannote",
                    displayName: "Pyannote 3.0 CPU VAD",
                    capability: "vad",
                    path: cachedVad.path,
                    detectedQuant: "onnx",
                    sourceLabel: "本地 Codex 缓存"
                ))
            }
        }

        return found
    }

    private static func findHuggingFaceSnapshot(
        hubRoot: URL,
        folderKeywords: [String],
        excludeKeywords: [String] = [],
        capability: String,
        requireMlxHint: Bool
    ) -> URL? {
        let fm = FileManager.default
        guard let repos = try? fm.contentsOfDirectory(
            at: hubRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let matchingRepos = repos
            .filter { url in
                let lower = url.lastPathComponent.lowercased()
                guard lower.hasPrefix("models--") else { return false }
                guard folderKeywords.allSatisfy({ lower.contains($0.lowercased()) }) else { return false }
                guard !excludeKeywords.contains(where: { lower.contains($0.lowercased()) }) else { return false }
                return true
            }
            .sorted { lhs, rhs in
                let lOwn = lhs.lastPathComponent.lowercased().contains("happenmasss--")
                let rOwn = rhs.lastPathComponent.lowercased().contains("happenmasss--")
                if lOwn != rOwn { return lOwn }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }

        for repo in matchingRepos {
            let snapshotsDir = repo.appendingPathComponent("snapshots")
            let refMain = repo.appendingPathComponent("refs/main")
            if let revRaw = try? String(contentsOf: refMain, encoding: .utf8) {
                let rev = revRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rev.isEmpty && !rev.contains("/") {
                    let mainSnap = snapshotsDir.appendingPathComponent(rev)
                    if isValidModelDirectory(mainSnap, capability: capability),
                       (!requireMlxHint || isMlxRepository(mainSnap))
                    {
                        return mainSnap
                    }
                }
            }

            guard let snaps = try? fm.contentsOfDirectory(
                at: snapshotsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for snap in snaps.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                if isValidModelDirectory(snap, capability: capability),
                   (!requireMlxHint || isMlxRepository(snap))
                {
                    return snap
                }
            }
        }
        return nil
    }

    private static func findFirstValidDirectory(
        roots: [URL],
        leafKeywords: [String],
        excludeLeafKeywords: [String] = [],
        capability: String,
        maxDepth: Int
    ) -> URL? {
        var candidates: [URL] = []
        for root in roots {
            collectValidDirs(
                at: root,
                remainingDepth: maxDepth,
                capability: capability,
                results: &candidates
            )
        }
        let sorted = candidates.sorted { $0.path > $1.path }
        return sorted.first { url in
            let leaf = url.lastPathComponent.lowercased()
            let allMatch = leafKeywords.allSatisfy { leaf.contains($0.lowercased()) }
            let excluded = excludeLeafKeywords.contains { leaf.contains($0.lowercased()) }
            return allMatch && !excluded
        }
    }

    private static func collectValidDirs(
        at url: URL,
        remainingDepth: Int,
        capability: String,
        results: inout [URL]
    ) {
        if isValidModelDirectory(url, capability: capability) {
            results.append(url)
            return
        }
        guard remainingDepth > 0 else { return }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for child in children.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            collectValidDirs(
                at: child,
                remainingDepth: remainingDepth - 1,
                capability: capability,
                results: &results
            )
        }
    }
}

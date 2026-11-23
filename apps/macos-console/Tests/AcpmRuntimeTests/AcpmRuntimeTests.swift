import AcpmClient
import AcpmRuntimeCore
import Foundation
import Testing

struct AcpmRuntimeTests {
    @Test func advisesHardwareTiersAndFormatsCounters() {
        let g8 = HardwareAdvisor.advise(physicalMemoryBytes: 8 * 1_073_741_824)
        #expect(g8.tier == .compact8GB)
        #expect(g8.ramGB == 8)

        let g16 = HardwareAdvisor.advise(physicalMemoryBytes: 16 * 1_073_741_824)
        #expect(g16.tier == .balanced16GB)
        #expect(g16.recommendedModels.contains("speech-vad-pyannote"))

        let g36 = HardwareAdvisor.advise(physicalMemoryBytes: 36 * 1_073_741_824)
        #expect(g36.tier == .pro24GBPlus)
        #expect(g36.recommendedModels.contains("qwen3-tts-1.7b"))

        #expect(HardwareAdvisor.formatIdleCountdown(1100) == "18m 20s")
        #expect(HardwareAdvisor.formatIdleCountdown(45) == "45s")
        #expect(HardwareAdvisor.formatIdleCountdown(3660) == "1h 1m")
        #expect(HardwareAdvisor.formatBytes(1_073_741_824) == "1.00 GB")

        let failure = DiagnosticFailure(
            timestampMs: 1763872800000,
            requestId: "req-xyz",
            caller: "yanmo-ime",
            modelId: "yanmo-correct-4b-cot",
            operation: "chat_completions",
            stage: "MODEL_PREPARE",
            code: .modelNotInstalled,
            detail: "MISSING_WEIGHT_FILES",
            nativeCode: nil,
            elapsedMs: 12
        )
        let copied = HardwareAdvisor.formatFailureDiagnostic(failure)
        #expect(copied.contains("request_id=req-xyz"))
        #expect(copied.contains("detail=MISSING_WEIGHT_FILES"))
    }

    @Test @MainActor func viewModelAppliesSystemEventsLive() {
        let vm = RuntimeViewModel()
        vm.models = [
            ModelStatusInfo(
                id: "yanmo-correct-4b-cot",
                capability: "llm",
                displayName: "Yanmo 4B CoT",
                selectedVariant: "darwin-arm64-mlx-8bit",
                installed: true,
                state: "STOPPED",
                pinPolicy: "auto",
                idleTimeoutSec: 1200,
                memory: ResourceVectorDTO(unifiedMB: 0)
            ),
        ]
        vm.config = SystemConfigResponse(
            budgetTier: "balanced",
            effectiveBudget: ResourceVectorDTO(unifiedMB: 16000),
            dataDir: "/tmp/data",
            modelsDir: "/tmp/data/models",
            voicesDir: "/tmp/data/voices",
            configPath: "/tmp/data/config.json",
            httpBaseUrl: "http://127.0.0.1:18790"
        )

        vm.applySystemEvent(.modelStateChanged(
            modelId: "yanmo-correct-4b-cot",
            state: "WARM",
            memory: ResourceVectorDTO(unifiedMB: 5265),
            tsMs: 123
        ))
        #expect(vm.models.first?.state == "WARM")
        #expect(vm.models.first?.memory.totalMB == 5265)
        #expect(vm.models.first?.idleRemainingSec == 1200)

        vm.applySystemEvent(.downloadProgress(ModelDownloadState(
            modelId: "qwen3-asr-0.6b",
            variantId: "darwin-arm64-mlx-4bit",
            status: .downloading,
            downloadedBytes: 512,
            totalBytes: 1024,
            filesCompleted: 0,
            filesTotal: 1,
            sha256Verified: false,
            updatedAt: "2026-11-23T12:00:00Z"
        )))
        #expect(vm.downloads["qwen3-asr-0.6b"]?.downloadedBytes == 512)

        vm.applySystemEvent(.batchProgress(SpeechBatchState(
            batchId: "sb_1",
            model: "qwen3-tts-1.7b",
            status: .running,
            total: 4,
            completed: 2,
            failed: 0,
            createdAt: "2026-11-23T12:00:00Z",
            updatedAt: "2026-11-23T12:00:05Z",
            items: []
        )))
        #expect(vm.batches.first?.completed == 2)

        vm.applySystemEvent(.configChanged(
            budgetTier: "eco",
            budget: ResourceVectorDTO(unifiedMB: 9800)
        ))
        #expect(vm.config?.budgetTier == "eco")
        #expect(vm.config?.effectiveBudget.totalMB == 9800)
        #expect(vm.liveEvents.count >= 2)
    }

    @Test func resolvesDaemonSpecFromWorkspaceOrBundledLayout() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("acpm-console-test-\(UUID().uuidString)")
        let contents = tmp.appendingPathComponent("AcpmRuntime.app/Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let helpers = contents.appendingPathComponent("Helpers")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let daemon = helpers.appendingPathComponent("acpmd")
        let mlx = helpers.appendingPathComponent("acpm-worker-mlx")
        let speech = helpers.appendingPathComponent("acpm-worker-speech")
        let reg = resources.appendingPathComponent("default-registry.json")
        for execURL in [daemon, mlx, speech] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: execURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)
        }
        try Data("{}".utf8).write(to: reg)

        let infoPlist = contents.appendingPathComponent("Info.plist")
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>com.acpm.test.runtime</string>
              <key>CFBundleExecutable</key><string>AcpmRuntime</string>
            </dict></plist>
            """.utf8
        ).write(to: infoPlist)
        let appExe = macos.appendingPathComponent("AcpmRuntime")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: appExe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appExe.path)

        let appBundle = try #require(Bundle(url: tmp.appendingPathComponent("AcpmRuntime.app")))
        let spec = try #require(DaemonSupervisor.resolveDaemonLaunchSpec(bundle: appBundle))
        #expect(spec.executableURL.path == daemon.path)
        #expect(spec.arguments.contains("--worker-mlx-bin"))
        #expect(spec.arguments.contains("--worker-speech-bin"))
        #expect(spec.arguments.contains(reg.path))
    }

    @Test func scansLocalMLXAndVadDirectoriesDeterministically() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acpm-scanner-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let llm9bSibling = root.appendingPathComponent(".cache/codex/models/yanmo-polish/2026-11-23/qwen38-9b-distill-sft-v6-mlx8")
        let hf4bRepo = root.appendingPathComponent(".cache/huggingface/hub/models--Happenmasss--yanmo-correct-4b-cot-mlx-8bit")
        let hf4bSnap = hf4bRepo.appendingPathComponent("snapshots/rev4b")
        let hf9bRepo = root.appendingPathComponent(".cache/huggingface/hub/models--Happenmasss--yanmo-correct-9b-cot-mlx-8bit")
        let hf9bSnap = hf9bRepo.appendingPathComponent("snapshots/rev9b")
        let nonMlxAsrDir = root.appendingPathComponent(".cache/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B-hf/snapshots/snap0")
        let asrDir = root.appendingPathComponent(".cache/huggingface/hub/models--mlx-community--Qwen3-ASR-0.6B-4bit/snapshots/snap1")
        let ttsVoiceDesign = root.appendingPathComponent(".cache/huggingface/local-models/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16")
        let ttsDir = root.appendingPathComponent(".cache/huggingface/local-models/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")
        let vadDir = root.appendingPathComponent("AppResources/models/speech-vad-pyannote")
        for dir in [llm9bSibling, hf4bSnap, hf9bSnap, nonMlxAsrDir, asrDir, ttsVoiceDesign, ttsDir, vadDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: hf4bRepo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hf9bRepo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("rev4b".utf8).write(to: hf4bRepo.appendingPathComponent("refs/main"))
        try Data("rev9b".utf8).write(to: hf9bRepo.appendingPathComponent("refs/main"))

        for dir in [llm9bSibling, hf4bSnap, hf9bSnap] {
            try Data(#"{"model_type":"qwen3_5","quantization":{"bits":8,"group_size":64}}"#.utf8)
                .write(to: dir.appendingPathComponent("config.json"))
            try Data("weights".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        }

        try Data(#"{"model_type":"qwen3_asr","torch_dtype":"bfloat16"}"#.utf8)
            .write(to: nonMlxAsrDir.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: nonMlxAsrDir.appendingPathComponent("model.safetensors"))

        try Data(#"{"model_type":"qwen3_asr","quantization":{"bits":4,"group_size":64}}"#.utf8)
            .write(to: asrDir.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: asrDir.appendingPathComponent("model.safetensors"))

        for dir in [ttsVoiceDesign, ttsDir] {
            try Data(#"{"model_type":"qwen3_tts","torch_dtype":"bfloat16"}"#.utf8)
                .write(to: dir.appendingPathComponent("config.json"))
            try Data("weights".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        }

        try Data("onnx".utf8).write(to: vadDir.appendingPathComponent("segmentation.onnx"))

        #expect(ModelPathScanner.detectQuant(in: hf4bSnap) == "8bit")
        #expect(ModelPathScanner.detectQuant(in: asrDir) == "4bit")
        #expect(ModelPathScanner.detectQuant(in: ttsDir) == "bf16")
        #expect(ModelPathScanner.isValidModelDirectory(hf4bSnap, capability: "llm"))
        #expect(ModelPathScanner.isValidModelDirectory(vadDir, capability: "vad"))

        let detected = ModelPathScanner.scanDefaultLocations(
            homeDirectory: root.resolvingSymlinksInPath(),
            bundleResourcesURL: root.resolvingSymlinksInPath().appendingPathComponent("AppResources")
        )
        let byId = Dictionary(uniqueKeysWithValues: detected.map { ($0.modelId, $0) })
        #expect(byId["yanmo-correct-4b-cot"]?.path == hf4bSnap.resolvingSymlinksInPath().path)
        #expect(byId["yanmo-correct-4b-cot"]?.detectedQuant == "8bit")
        #expect(byId["yanmo-correct-9b-cot"]?.path == hf9bSnap.resolvingSymlinksInPath().path)
        #expect(byId["qwen3-asr-0.6b"]?.path == asrDir.resolvingSymlinksInPath().path)
        #expect(byId["qwen3-tts-1.7b"]?.path == ttsDir.resolvingSymlinksInPath().path)
        #expect(byId["speech-vad-pyannote"]?.path == vadDir.resolvingSymlinksInPath().path)
        #expect(byId["speech-vad-pyannote"]?.sourceLabel.contains("内置") == true)
    }

    @Test func exportsRedactedDiagnosticsWithoutBearerTokenOrPayloads() throws {
        let secretToken = "sk-acpm-super-secret-bearer-token-999"
        let discJSON = """
        {
          "version": 1,
          "pid": 777,
          "started_at": "2026-11-23T15:00:00Z",
          "http_base_url": "http://127.0.0.1:18790",
          "native_ipc_path": "/tmp/acpm.sock",
          "token": "\(secretToken)",
          "platform": "darwin-arm64",
          "capabilities": ["llm", "asr", "tts", "vad"],
          "mdns_hostname": "acpm.local",
          "mdns_base_url": "http://acpm.local:18790"
        }
        """
        let disc = try JSONDecoder().decode(RuntimeDiscovery.self, from: Data(discJSON.utf8))
        let cfg = SystemConfigResponse(
            budgetTier: "balanced",
            effectiveBudget: ResourceVectorDTO(unifiedMB: 16000),
            dataDir: "/tmp/data",
            modelsDir: "/tmp/data/models",
            voicesDir: "/tmp/data/voices",
            configPath: "/tmp/data/config.json",
            mdnsHostname: "acpm.local",
            mdnsBaseUrl: "http://acpm.local:18790",
            httpBaseUrl: "http://127.0.0.1:18790"
        )
        let status = SystemStatusResponse(
            platform: "darwin-arm64",
            pid: 777,
            budget: ResourceVectorDTO(unifiedMB: 16000),
            used: ResourceVectorDTO(unifiedMB: 140),
            memoryPressure: "normal",
            thermalState: "nominal",
            loadedModels: [],
            activeRequests: 0,
            queuedRequests: 0,
            callerCounts: ["yanmo-ime": 3]
        )

        let data = try DiagnosticsExporter.buildJSONData(
            appVersion: "0.2.0",
            hardware: HardwareAdvisor.advise(physicalMemoryBytes: 24 * 1_073_741_824),
            connected: true,
            discovery: disc,
            status: status,
            models: [],
            config: cfg,
            recentFailures: []
        )
        let rawText = String(decoding: data, as: UTF8.self)
        #expect(!rawText.contains(secretToken))
        #expect(!rawText.contains(#""token""#))
        #expect(rawText.contains("acpm.local"))
        #expect(rawText.contains("yanmo-ime"))

        let decoded = try JSONDecoder().decode(RedactedDiagnosticsBundle.self, from: data)
        #expect(decoded.appVersion == "0.2.0")
        #expect(decoded.hostRamGB == 24)
        #expect(decoded.systemStatus?.pid == 777)
    }

    @Test @MainActor func managesAppearanceTabsToastAndOnboardingState() throws {
        let suiteName = "com.acpm.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ConsoleTab.allCases.count == 5)
        #expect(ConsoleTab.allCases.contains(.playground))
        #expect(ConsoleTab.allCases.contains(.voices))

        let vm = RuntimeViewModel(userDefaults: defaults)
        #expect(vm.appearance == .system)
        #expect(vm.hasCompletedOnboarding == false)
        #expect(vm.statusBarVisualState == .offline)

        vm.connected = true
        #expect(vm.statusBarVisualState == .idle)

        vm.models = [
            ModelStatusInfo(
                id: "yanmo-correct-4b-cot",
                capability: "llm",
                displayName: "Yanmo 4B CoT",
                selectedVariant: "darwin-arm64-mlx-8bit",
                installed: true,
                state: "RUNNING",
                pinPolicy: "auto",
                idleTimeoutSec: 1200,
                memory: ResourceVectorDTO(unifiedMB: 5100)
            ),
        ]
        #expect(vm.statusBarVisualState == .busy)
        #expect(vm.hasActiveRuntimeWork == true)

        vm.appearance = .dark
        vm.completeOnboarding(navigateToPlayground: true)
        #expect(vm.selectedTab == .playground)

        vm.showToast("测试提示", kind: .success)
        #expect(vm.toast?.message == "测试提示")
        #expect(vm.toast?.kind == .success)

        vm.showToast("严重错误", kind: .error)
        #expect(vm.toast?.kind == .error)
        #expect(vm.lastErrorMessage == "严重错误")

        #expect(RuntimeViewModel.abbreviateHomePath("/Users/demo/models/a", homePath: "/Users/demo") == "~/models/a")
        #expect(RuntimeViewModel.localizedBatchStatus(.completedWithErrors) == "部分失败")
        #expect(RuntimeViewModel.localizedDownloadStatus(.verifying) == "校验中")

        let vmReloaded = RuntimeViewModel(userDefaults: defaults)
        #expect(vmReloaded.appearance == .dark)
        #expect(vmReloaded.hasCompletedOnboarding == true)
    }
}

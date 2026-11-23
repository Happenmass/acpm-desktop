import AcpmClient
import AppKit
import Foundation
import Observation

public enum ConsoleTab: String, CaseIterable, Identifiable, Sendable {
    case overview = "概览"
    case models = "模型"
    case playground = "演练台"
    case jobs = "任务"
    case voices = "音色库"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .models: return "cube.box.fill"
        case .playground: return "sparkles.rectangle.stack"
        case .jobs: return "bolt.horizontal.circle"
        case .voices: return "waveform.and.mic"
        }
    }
}

public enum StatusBarVisualState: Sendable, Equatable {
    case offline
    case idle
    case busy
}

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

public enum ToastKind: String, Sendable, Equatable {
    case info
    case success
    case warning
    case error
}

public struct ToastNotification: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: ToastKind
    public let message: String

    public init(id: UUID = UUID(), kind: ToastKind, message: String) {
        self.id = id
        self.kind = kind
        self.message = message
    }
}

public struct MemorySample: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let totalMB: UInt64
    public let perModelMB: [String: UInt64]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        totalMB: UInt64,
        perModelMB: [String: UInt64] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.totalMB = totalMB
        self.perModelMB = perModelMB
    }
}

public struct LiveEventItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let kind: String
    public let summary: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), kind: String, summary: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
    }
}

@Observable
@MainActor
public final class RuntimeViewModel {
    private static let appearanceDefaultsKey = "acpm.appearance"
    private static let onboardingDefaultsKey = "acpm.hasCompletedOnboarding"

    public var selectedTab: ConsoleTab = .overview
    public var appearance: AppAppearance {
        didSet {
            userDefaults.set(appearance.rawValue, forKey: Self.appearanceDefaultsKey)
        }
    }
    public var hasCompletedOnboarding: Bool {
        didSet {
            userDefaults.set(hasCompletedOnboarding, forKey: Self.onboardingDefaultsKey)
        }
    }
    public var showOnboardingSheet = false
    public var detectedLocalModels: [DetectedLocalModel] = []

    public var connected = false
    public var isStartingDaemon = false
    public var status: SystemStatusResponse?
    public var models: [ModelStatusInfo] = []
    public var voices: [VoiceProfile] = []
    public var batches: [SpeechBatchState] = []
    public var downloads: [String: ModelDownloadState] = [:]
    public var config: SystemConfigResponse?
    public var recentFailures: [DiagnosticFailure] = []
    public var discovery: RuntimeDiscovery?
    public var memoryHistory: [MemorySample] = []
    public var liveEvents: [LiveEventItem] = []
    public var actionMessage: String?
    public var lastErrorMessage: String?
    public var toast: ToastNotification?
    public var pendingModelIds: Set<String> = []
    public var isUnloadingAll = false
    public var isRestartingDaemon = false

    // Playground — LLM
    public var playgroundSelectedLLMId = "yanmo-correct-4b-cot"
    public var playgroundSystemPrompt = "你是言墨语音输入法纠错助手，请修正用户口述文本中的同音错别字和标点断句，只输出纠错后的最终文本。"
    public var playgroundPrompt = "今天下午三点在会议室开会大家不要忘了带上那个新版本的硬件测试报告哦"
    public var playgroundSeparateReasoning = true
    public var playgroundReasoningText = ""
    public var playgroundAnswerText = ""
    public var playgroundLLMLoading = false
    public var playgroundLLMTtftMs: Double?
    public var playgroundLLMTotalMs: Double?

    // Playground — VAD & ASR
    public var playgroundSelectedAsrId = "qwen3-asr-0.6b"
    public var playgroundAudioPath = ""
    public var playgroundVadResult: VadResponse?
    public var playgroundAsrResult: TranscriptionResponse?
    public var playgroundVadMs: Double?
    public var playgroundAsrMs: Double?
    public var playgroundAudioLoading = false

    // Playground — TTS
    public var playgroundTTSText = "你好，这是本地苹果芯片人工智能运行时，正在演示实时音色克隆合成效果。"
    public var playgroundSelectedVoiceId = ""
    public var playgroundTTSLoading = false
    public var playgroundTTSLastDurationMs: Double?
    public var playgroundTTSLastBytes: Int?

    public let daemonSupervisor: DaemonSupervisor
    public let loginItem: LoginItemManager
    public let audioPreviewer: VoiceAudioPreviewer
    public let hardwareRecommendation: HardwareRecommendation

    private let userDefaults: UserDefaults
    private var pollingTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?
    private var playgroundLLMTask: Task<Void, Never>?
    private var hasAttemptedAutoLaunch = false

    public init(
        daemonSupervisor: DaemonSupervisor = DaemonSupervisor(),
        loginItem: LoginItemManager = LoginItemManager(),
        audioPreviewer: VoiceAudioPreviewer = VoiceAudioPreviewer(),
        hardwareRecommendation: HardwareRecommendation = HardwareAdvisor.advise(),
        userDefaults: UserDefaults = .standard
    ) {
        self.daemonSupervisor = daemonSupervisor
        self.loginItem = loginItem
        self.audioPreviewer = audioPreviewer
        self.hardwareRecommendation = hardwareRecommendation
        self.userDefaults = userDefaults

        let savedAppearance = userDefaults.string(forKey: Self.appearanceDefaultsKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        self.appearance = savedAppearance
        self.hasCompletedOnboarding = userDefaults.bool(forKey: Self.onboardingDefaultsKey)
    }

    public func showToast(_ message: String, kind: ToastKind = .info, autoDismissSec: Double? = nil) {
        toastDismissTask?.cancel()
        toast = ToastNotification(kind: kind, message: message)
        switch kind {
        case .error:
            lastErrorMessage = message
        case .info, .success, .warning:
            actionMessage = message
        }
        let duration: Double? = autoDismissSec ?? (kind == .error ? nil : 3.0)
        if let duration {
            toastDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                if !Task.isCancelled {
                    self?.toast = nil
                }
            }
        }
    }

    public var statusBarVisualState: StatusBarVisualState {
        if !connected { return .offline }
        let busyModels = models.contains {
            let st = $0.state.uppercased()
            return st == "RUNNING" || st == "LOADING" || st == "UNLOADING"
        }
        let busyDownloads = downloads.values.contains {
            $0.status == .downloading || $0.status == .verifying || $0.status == .queued
        }
        let busyBatches = batches.contains { $0.status == .running || $0.status == .queued }
        if (status?.activeRequests ?? 0) > 0 || busyModels || busyDownloads || busyBatches {
            return .busy
        }
        return .idle
    }

    public var hasActiveRuntimeWork: Bool {
        guard connected else { return false }
        let activeReq = (status?.activeRequests ?? 0) > 0 || (status?.queuedRequests ?? 0) > 0
        let activeJobs = batches.contains { $0.status == .running || $0.status == .queued || $0.status == .paused }
            || downloads.values.contains { $0.status == .downloading || $0.status == .verifying || $0.status == .queued }
        let loadedModels = models.contains { $0.state != "STOPPED" && $0.capability != "diarization" }
        return activeReq || activeJobs || loadedModels
    }

    public var preferredInstalledTtsModel: ModelStatusInfo? {
        models.first(where: { $0.capability == "tts" && $0.installed && $0.state != "STOPPED" })
            ?? models.first(where: { $0.capability == "tts" && $0.installed })
    }

    public func dismissToast() {
        toastDismissTask?.cancel()
        toast = nil
    }

    public func startMonitoring() {
        if !hasAttemptedAutoLaunch {
            hasAttemptedAutoLaunch = true
            Task { [weak self] in
                await self?.ensureDaemonRunningAndRefresh()
            }
        }
        daemonSupervisor.registerSleepHandler {
            guard let client = try? AcpmClient.fromDefaultDiscovery(caller: "acpm-console-sleep") else {
                return
            }
            try? await client.unloadAll(includePinned: false)
        }
        if pollingTask == nil {
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        if eventsTask == nil {
            eventsTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let client = try? AcpmClient.fromDefaultDiscovery(caller: "acpm-console-sse") else {
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }
                    do {
                        for try await ev in client.systemEventsStream() {
                            if Task.isCancelled { break }
                            self?.applySystemEvent(ev)
                        }
                    } catch {
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
        }
    }

    public func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        playgroundLLMTask?.cancel()
        playgroundLLMTask = nil
    }

    public func ensureDaemonRunningAndRefresh() async {
        isStartingDaemon = true
        let err = await daemonSupervisor.ensureRunning()
        isStartingDaemon = false
        if let err {
            lastErrorMessage = err
        } else {
            lastErrorMessage = nil
        }
        await refresh()
    }

    public func refresh() async {
        do {
            let disc = try RuntimeDiscovery.discover()
            let client = try AcpmClient(discovery: disc, caller: "acpm-console")
            async let statusTask = client.systemStatus()
            async let modelsTask = client.models()
            async let failuresTask = client.recentFailures()
            async let voicesTask = client.listVoices()
            async let batchesTask = client.listSpeechBatches()
            async let downloadsTask = client.listDownloads()
            async let configTask = client.systemConfig()

            let (
                nextStatus,
                nextModels,
                nextFailures,
                nextVoices,
                nextBatches,
                nextDownloads,
                nextConfig,
            ) = try await (
                statusTask,
                modelsTask,
                failuresTask,
                voicesTask,
                batchesTask,
                downloadsTask,
                configTask
            )

            self.discovery = disc
            self.status = nextStatus
            self.models = nextModels
            self.recentFailures = nextFailures
            self.voices = nextVoices
            self.batches = nextBatches
            self.config = nextConfig

            if playgroundSelectedVoiceId.isEmpty, let firstVoice = nextVoices.first {
                playgroundSelectedVoiceId = firstVoice.voiceId
            } else if !playgroundSelectedVoiceId.isEmpty,
                      !nextVoices.contains(where: { $0.voiceId == playgroundSelectedVoiceId })
            {
                playgroundSelectedVoiceId = nextVoices.first?.voiceId ?? ""
            }

            var dlMap: [String: ModelDownloadState] = [:]
            for dl in nextDownloads {
                dlMap[dl.modelId] = dl
            }
            self.downloads = dlMap
            self.connected = true
            self.lastErrorMessage = nil

            var perModel: [String: UInt64] = [:]
            for m in nextModels where m.state != "STOPPED" && m.memory.totalMB > 0 {
                perModel[m.id] = m.memory.totalMB
            }
            self.memoryHistory.append(MemorySample(totalMB: nextStatus.used.totalMB, perModelMB: perModel))
            if self.memoryHistory.count > 150 {
                self.memoryHistory.removeFirst(self.memoryHistory.count - 150)
            }
        } catch {
            self.connected = false
            self.lastErrorMessage = error.localizedDescription
        }
    }

    public func applySystemEvent(_ event: SystemEventEnvelope) {
        switch event {
        case .modelStateChanged(let modelId, let state, let memory, _):
            if let idx = models.firstIndex(where: { $0.id == modelId }) {
                let prev = models[idx]
                models[idx] = ModelStatusInfo(
                    id: prev.id,
                    capability: prev.capability,
                    displayName: prev.displayName,
                    selectedVariant: prev.selectedVariant,
                    installed: prev.installed,
                    state: state,
                    pinPolicy: prev.pinPolicy,
                    idleTimeoutSec: prev.idleTimeoutSec,
                    idleRemainingSec: state == "WARM" && prev.pinPolicy != "pinned" ? prev.idleTimeoutSec : nil,
                    availableQuants: prev.availableQuants,
                    modelPath: prev.modelPath,
                    memory: memory
                )
            }
            appendLiveEvent(kind: "模型状态", summary: "\(modelId) -> \(state) (\(memory.totalMB) MB)")

        case .failureRecorded(let failure):
            recentFailures.removeAll { $0.requestId == failure.requestId && $0.timestampMs == failure.timestampMs }
            recentFailures.insert(failure, at: 0)
            if recentFailures.count > 20 {
                recentFailures = Array(recentFailures.prefix(20))
            }
            appendLiveEvent(kind: "诊断告警", summary: "\(failure.operation) \(failure.code.rawValue): \(failure.detail)")

        case .batchProgress(let batch):
            if let idx = batches.firstIndex(where: { $0.batchId == batch.batchId }) {
                batches[idx] = batch
            } else {
                batches.insert(batch, at: 0)
            }
            appendLiveEvent(kind: "批量合成", summary: "\(batch.batchId) \(batch.status.rawValue) (\(batch.completed)/\(batch.total))")

        case .downloadProgress(let dl):
            downloads[dl.modelId] = dl
            if dl.status == .completed || dl.status == .failed || dl.status == .cancelled {
                appendLiveEvent(kind: "模型下载", summary: "\(dl.modelId) -> \(dl.status.rawValue)")
                if dl.status == .completed {
                    Task { [weak self] in await self?.refresh() }
                }
            }

        case .configChanged(let tier, let budget):
            if let cur = config {
                config = SystemConfigResponse(
                    budgetTier: tier,
                    budgetOverrideMb: cur.budgetOverrideMb,
                    effectiveBudget: budget,
                    dataDir: cur.dataDir,
                    modelsDir: cur.modelsDir,
                    voicesDir: cur.voicesDir,
                    configPath: cur.configPath,
                    mdnsHostname: cur.mdnsHostname,
                    mdnsBaseUrl: cur.mdnsBaseUrl,
                    httpBaseUrl: cur.httpBaseUrl,
                    modelOverrides: cur.modelOverrides
                )
            }
            appendLiveEvent(kind: "配置变更", summary: "预算档位切换为 \(tier) (\(budget.totalMB) MB)")

        case .unknown(let raw):
            appendLiveEvent(kind: "系统事件", summary: raw)
        }
    }

    private func appendLiveEvent(kind: String, summary: String) {
        liveEvents.insert(LiveEventItem(kind: kind, summary: summary), at: 0)
        if liveEvents.count > 60 {
            liveEvents = Array(liveEvents.prefix(60))
        }
    }

    private func makeClient(caller: String = "acpm-console") -> AcpmClient? {
        try? AcpmClient.fromDefaultDiscovery(caller: caller)
    }

    @discardableResult
    public func scanLocalModels() -> [DetectedLocalModel] {
        let found = ModelPathScanner.scanDefaultLocations()
        detectedLocalModels = found
        return found
    }

    public func openOnboarding() {
        _ = scanLocalModels()
        showOnboardingSheet = true
    }

    public func completeOnboarding(navigateToPlayground: Bool = true) {
        hasCompletedOnboarding = true
        showOnboardingSheet = false
        if navigateToPlayground {
            selectedTab = .playground
        }
    }

    public func restartDaemon() async {
        guard !isRestartingDaemon else { return }
        isRestartingDaemon = true
        defer { isRestartingDaemon = false }
        daemonSupervisor.stopManagedDaemonIfOwned()
        try? await Task.sleep(for: .milliseconds(450))
        await ensureDaemonRunningAndRefresh()
        if connected {
            showToast("AI 服务已重启并就绪", kind: .success)
        }
    }

    @discardableResult
    public func bindDetectedModels(_ items: [DetectedLocalModel], silent: Bool = false) async -> Int {
        guard let client = makeClient() else {
            showToast("未连接到 acpmd，无法绑定模型路径", kind: .error)
            return 0
        }
        var boundCount = 0
        for item in items {
            do {
                _ = try await client.updateModelConfig(
                    item.modelId,
                    update: UpdateModelConfigRequest(
                        quant: item.detectedQuant,
                        path: item.path
                    )
                )
                boundCount += 1
            } catch {
                showToast("绑定 \(item.modelId) 失败：\(describeError(error))", kind: .error)
            }
        }
        await refresh()
        if boundCount > 0 && !silent {
            showToast("已成功绑定 \(boundCount) 个本地模型目录", kind: .success)
        }
        return boundCount
    }

    @discardableResult
    public func updateModelPath(_ id: String, path: String) async -> Bool {
        guard let client = makeClient() else { return false }
        pendingModelIds.insert(id)
        defer { pendingModelIds.remove(id) }
        let url = URL(fileURLWithPath: path)
        let quant = ModelPathScanner.detectQuant(in: url)
        do {
            _ = try await client.updateModelConfig(
                id,
                update: UpdateModelConfigRequest(quant: quant, path: path)
            )
            showToast("已绑定 \(id) 至本地目录", kind: .success)
            await refresh()
            return true
        } catch {
            showToast(describeError(error), kind: .error)
            await refresh()
            return false
        }
    }

    public func loadModel(_ id: String) async {
        guard !pendingModelIds.contains(id), let client = makeClient() else { return }
        pendingModelIds.insert(id)
        defer { pendingModelIds.remove(id) }
        do {
            _ = try await client.loadModel(id)
            showToast("已预热 \(id)", kind: .success)
        } catch {
            showToast(describeError(error), kind: .error)
        }
        await refresh()
    }

    public func unloadModel(_ id: String) async {
        guard !pendingModelIds.contains(id), let client = makeClient() else { return }
        pendingModelIds.insert(id)
        defer { pendingModelIds.remove(id) }
        do {
            _ = try await client.unloadModel(id)
            showToast("已卸载 \(id)", kind: .info)
        } catch {
            showToast(describeError(error), kind: .error)
        }
        await refresh()
    }

    public func unloadAll(includePinned: Bool = false) async {
        guard !isUnloadingAll, let client = makeClient() else { return }
        isUnloadingAll = true
        defer { isUnloadingAll = false }
        do {
            try await client.unloadAll(includePinned: includePinned)
            showToast("已释放空闲模型内存", kind: .success)
        } catch {
            showToast(describeError(error), kind: .error)
        }
        await refresh()
    }

    @discardableResult
    public func updateModelConfig(
        _ id: String,
        pinPolicy: String? = nil,
        idleTimeoutSec: UInt64? = nil,
        quant: String? = nil,
        silent: Bool = false
    ) async -> Bool {
        guard let client = makeClient() else { return false }
        do {
            _ = try await client.updateModelConfig(
                id,
                update: UpdateModelConfigRequest(
                    pinPolicy: pinPolicy,
                    idleTimeoutSec: idleTimeoutSec,
                    quant: quant
                )
            )
            if !silent {
                showToast("已保存 \(id) 调度策略", kind: .success)
            }
            await refresh()
            return true
        } catch {
            showToast(describeError(error), kind: .error)
            await refresh()
            return false
        }
    }

    public func startDownload(_ id: String, quant: String? = nil) async {
        guard !pendingModelIds.contains(id), let client = makeClient() else { return }
        pendingModelIds.insert(id)
        defer { pendingModelIds.remove(id) }
        do {
            let st = try await client.startModelDownload(id, quant: quant)
            downloads[id] = st
            showToast("已加入下载队列：\(id)", kind: .info)
        } catch {
            showToast(describeError(error), kind: .error)
        }
    }

    public func cancelDownload(_ id: String) async {
        guard !pendingModelIds.contains(id), let client = makeClient() else { return }
        pendingModelIds.insert(id)
        defer { pendingModelIds.remove(id) }
        do {
            let st = try await client.cancelModelDownload(id)
            downloads[id] = st
            showToast("已取消下载：\(id)", kind: .warning)
        } catch {
            showToast(describeError(error), kind: .error)
        }
    }

    public func deleteModel(_ id: String) async {
        guard !pendingModelIds.contains(id), let client = makeClient() else { return }
        pendingModelIds.insert(id)
        defer { pendingModelIds.remove(id) }
        do {
            try await client.deleteModel(id)
            showToast("已删除托管模型文件：\(id)", kind: .info)
        } catch {
            showToast(describeError(error), kind: .error)
        }
        await refresh()
    }

    public func registerVoice(
        name: String,
        referenceAudio: String,
        referenceText: String?,
        language: String?,
        notes: String?
    ) async -> Bool {
        guard let client = makeClient() else { return false }
        do {
            let profile = try await client.registerVoice(
                CreateVoiceRequest(
                    name: name,
                    referenceAudio: referenceAudio,
                    referenceText: referenceText?.isEmpty == true ? nil : referenceText,
                    language: language?.isEmpty == true ? nil : language,
                    notes: notes?.isEmpty == true ? nil : notes
                )
            )
            playgroundSelectedVoiceId = profile.voiceId
            showToast("已注册音色：\(profile.name)", kind: .success)
            await refresh()
            return true
        } catch {
            showToast(describeError(error), kind: .error)
            return false
        }
    }

    public func togglePlayVoiceSample(_ voiceId: String) async {
        if audioPreviewer.playingVoiceId == voiceId {
            audioPreviewer.stop()
            return
        }
        guard let client = makeClient() else { return }
        do {
            let wav = try await client.downloadVoiceSample(voiceId)
            audioPreviewer.play(voiceId: voiceId, wavData: wav)
        } catch {
            showToast(describeError(error), kind: .error)
        }
    }

    public func stopAudioPlayback() {
        audioPreviewer.stop()
    }

    public func deleteVoice(_ voiceId: String) async {
        if audioPreviewer.playingVoiceId == voiceId {
            audioPreviewer.stop()
        }
        guard let client = makeClient() else { return }
        do {
            try await client.deleteVoice(voiceId)
            showToast("已删除音色 \(voiceId)", kind: .info)
        } catch {
            showToast(describeError(error), kind: .error)
        }
        await refresh()
    }

    public func submitSpeechBatch(
        voiceId: String?,
        lines: [String],
        outputDir: String,
        modelId: String = "qwen3-tts-1.7b"
    ) async -> Bool {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            showToast("请输入至少一句台词文本", kind: .warning)
            return false
        }
        guard let client = makeClient(caller: "acpm-console-batch") else { return false }
        let items = cleaned.enumerated().map { idx, text in
            SpeechBatchItemInput(
                id: String(format: "s%03d", idx + 1),
                text: text,
                outputFile: String(format: "%03d.wav", idx + 1)
            )
        }
        do {
            let st = try await client.createSpeechBatch(
                CreateSpeechBatchRequest(
                    model: modelId,
                    voice: voiceId?.isEmpty == true ? nil : voiceId,
                    outputDir: outputDir,
                    items: items
                )
            )
            showToast("已提交批量合成任务 \(st.batchId)（共 \(st.total) 句）", kind: .success)
            await refresh()
            return true
        } catch {
            showToast(describeError(error), kind: .error)
            return false
        }
    }

    public func pauseBatch(_ batchId: String) async {
        guard let client = makeClient() else { return }
        do {
            _ = try await client.pauseSpeechBatch(batchId)
            showToast("已暂停任务 \(batchId)", kind: .info)
        } catch {
            showToast(describeError(error), kind: .error)
        }
        await refresh()
    }

    public func resumeBatch(_ batchId: String) async {
        guard let client = makeClient() else { return }
        do {
            _ = try await client.resumeSpeechBatch(batchId)
            showToast("已恢复任务 \(batchId)", kind: .success)
        } catch {
            showToast(describeError(error), kind: .error)
        }
        await refresh()
    }

    public func cancelBatch(_ batchId: String) async {
        guard let client = makeClient() else { return }
        do {
            _ = try await client.cancelSpeechBatch(batchId)
            showToast("已取消任务 \(batchId)", kind: .warning)
        } catch {
            showToast(describeError(error), kind: .error)
        }
        await refresh()
    }

    @discardableResult
    public func updateBudgetTier(_ tier: String, silent: Bool = false) async -> Bool {
        guard let client = makeClient() else { return false }
        do {
            config = try await client.updateSystemConfig(
                UpdateSystemConfigRequest(budgetTier: tier, clearBudgetOverride: true)
            )
            if !silent {
                showToast("预算档位已切换至 \(tier)", kind: .success)
            }
            await refresh()
            return true
        } catch {
            showToast(describeError(error), kind: .error)
            await refresh()
            return false
        }
    }

    @discardableResult
    public func updateBudgetOverride(mb: UInt64?, silent: Bool = false) async -> Bool {
        guard let client = makeClient() else { return false }
        do {
            if let mb {
                config = try await client.updateSystemConfig(
                    UpdateSystemConfigRequest(budgetOverrideMb: mb)
                )
                if !silent {
                    showToast("已设置自定义内存预算 \(mb) MB", kind: .success)
                }
            } else {
                config = try await client.updateSystemConfig(
                    UpdateSystemConfigRequest(clearBudgetOverride: true)
                )
                if !silent {
                    showToast("已恢复自动分档预算", kind: .info)
                }
            }
            await refresh()
            return true
        } catch {
            showToast(describeError(error), kind: .error)
            await refresh()
            return false
        }
    }

    // MARK: - Playground

    public func runPlaygroundLLMStream(modelId: String? = nil) {
        playgroundLLMTask?.cancel()
        guard let client = makeClient(caller: "acpm-playground") else {
            showToast("未连接到 acpmd，无法执行流式推理", kind: .error)
            return
        }
        let targetModel = modelId ?? playgroundSelectedLLMId
        let prompt = playgroundPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            showToast("请输入要测试的提示词或纠错文本", kind: .warning)
            return
        }

        playgroundReasoningText = ""
        playgroundAnswerText = ""
        playgroundLLMTtftMs = nil
        playgroundLLMTotalMs = nil
        playgroundLLMLoading = true

        var messages: [ChatMessage] = []
        let sys = playgroundSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            messages.append(ChatMessage(role: "system", content: sys))
        }
        messages.append(ChatMessage(role: "user", content: prompt))

        let req = ChatCompletionRequest(
            model: targetModel,
            messages: messages,
            stream: true,
            temperature: 0.0,
            maxTokens: 512,
            separateReasoning: playgroundSeparateReasoning
        )

        let start = CFAbsoluteTimeGetCurrent()
        playgroundLLMTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await delta in client.chatCompletionsStream(req, priority: .interactive) {
                    if Task.isCancelled { break }
                    if self.playgroundLLMTtftMs == nil,
                       (delta.reasoningContent != nil || delta.content != nil)
                    {
                        self.playgroundLLMTtftMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                    }
                    if let r = delta.reasoningContent {
                        self.playgroundReasoningText += r
                    }
                    if let c = delta.content {
                        self.playgroundAnswerText += c
                    }
                }
                self.playgroundLLMTotalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                self.playgroundLLMLoading = false
                await self.refresh()
            } catch {
                self.playgroundLLMLoading = false
                if !Task.isCancelled {
                    self.showToast(self.describeError(error), kind: .error)
                }
            }
        }
    }

    public func stopPlaygroundLLM() {
        playgroundLLMTask?.cancel()
        playgroundLLMTask = nil
        playgroundLLMLoading = false
    }

    public func runPlaygroundVad(filePath: String) async {
        guard let client = makeClient(caller: "acpm-playground") else {
            showToast("未连接到 acpmd", kind: .error)
            return
        }
        playgroundAudioLoading = true
        defer { playgroundAudioLoading = false }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let res = try await client.vad(VadRequest(filePath: filePath))
            playgroundVadResult = res
            playgroundVadMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            showToast("CPU VAD 检出 \(res.segments.count) 段语音", kind: .success)
        } catch {
            showToast(describeError(error), kind: .error)
        }
    }

    public func runPlaygroundAsr(filePath: String, modelId: String? = nil, runVadFirst: Bool = true) async {
        guard let client = makeClient(caller: "acpm-playground") else {
            showToast("未连接到 acpmd", kind: .error)
            return
        }
        playgroundAudioLoading = true
        defer { playgroundAudioLoading = false }

        if runVadFirst {
            let vadStart = CFAbsoluteTimeGetCurrent()
            if let vadRes = try? await client.vad(VadRequest(filePath: filePath)) {
                playgroundVadResult = vadRes
                playgroundVadMs = (CFAbsoluteTimeGetCurrent() - vadStart) * 1000.0
            }
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let res = try await client.transcribe(
                TranscriptionRequest(
                    model: modelId ?? playgroundSelectedAsrId,
                    filePath: filePath,
                    vadFilter: runVadFirst,
                    timestamps: true
                )
            )
            playgroundAsrResult = res
            playgroundAsrMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            showToast("ASR 转写完成", kind: .success)
            await refresh()
        } catch {
            showToast(describeError(error), kind: .error)
        }
    }

    public func runPlaygroundTTS(voiceId: String?, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("请输入要合成的文本", kind: .warning)
            return
        }
        guard let client = makeClient(caller: "acpm-playground") else {
            showToast("未连接到 acpmd", kind: .error)
            return
        }
        playgroundTTSLoading = true
        defer { playgroundTTSLoading = false }
        let ttsModelId = preferredInstalledTtsModel?.id ?? "qwen3-tts-1.7b"
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let wav = try await client.speechAudio(
                SpeechRequest(
                    model: ttsModelId,
                    input: trimmed,
                    voice: voiceId?.isEmpty == true ? nil : voiceId
                ),
                priority: .normal
            )
            playgroundTTSLastDurationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            playgroundTTSLastBytes = wav.count
            audioPreviewer.play(voiceId: "__playground__", wavData: wav)
            showToast("音色合成完成（\(HardwareAdvisor.formatBytes(UInt64(wav.count)))），正在试听", kind: .success)
            await refresh()
        } catch {
            showToast(describeError(error), kind: .error)
        }
    }

    // MARK: - Utilities & Export

    public static func abbreviateHomePath(
        _ path: String,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }

    public static func localizedBatchStatus(_ status: SpeechBatchStatus) -> String {
        switch status {
        case .queued: return "排队中"
        case .running: return "运行中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .completedWithErrors: return "部分失败"
        case .cancelled: return "已取消"
        }
    }

    public static func localizedBatchItemState(_ state: SpeechBatchItemState) -> String {
        switch state {
        case .pending: return "等待"
        case .running: return "生成中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    public static func localizedDownloadStatus(_ status: ModelDownloadStatus) -> String {
        switch status {
        case .queued: return "排队中"
        case .downloading: return "下载中"
        case .verifying: return "校验中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    public func exportRedactedDiagnosticsJSON() -> Data? {
        try? DiagnosticsExporter.buildJSONData(
            hardware: hardwareRecommendation,
            connected: connected,
            discovery: discovery,
            status: status,
            models: models,
            config: config,
            recentFailures: recentFailures
        )
    }

    public func copyToPasteboard(_ text: String, notice: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let notice {
            showToast(notice, kind: .success)
        }
    }

    public func openDataDirectoryInFinder() {
        guard let path = config?.dataDir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func quitRuntime() {
        stopMonitoring()
        audioPreviewer.stop()
        daemonSupervisor.stopManagedDaemonIfOwned()
        NSApplication.shared.terminate(nil)
    }

    private func describeError(_ error: Error) -> String {
        if let acpmErr = error as? AcpmError {
            return "[\(acpmErr.code.rawValue)] \(acpmErr.message)"
        }
        return error.localizedDescription
    }
}

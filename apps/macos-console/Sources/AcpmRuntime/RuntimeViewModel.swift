import AcpmClient
import Foundation
import Observation

enum ConsoleTab: String, CaseIterable, Identifiable {
    case overview = "概览"
    case models = "模型"
    case jobs = "任务"
    case voicesAndSettings = "音色与设置"

    var id: String { rawValue }
}

struct DaemonLauncher: Sendable {
    static func bundledDaemonURL() -> URL? {
        guard let execURL = Bundle.main.executableURL else { return nil }
        let helpersDir = execURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers")
        let candidate = helpersDir.appendingPathComponent("acpmd")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}

@Observable
@MainActor
final class RuntimeViewModel {
    var selectedTab: ConsoleTab = .overview
    var connected = false
    var status: SystemStatusResponse?
    var models: [ModelStatusInfo] = []
    var recentFailures: [DiagnosticFailure] = []
    var memoryHistoryMB: [UInt64] = []
    var lastErrorMessage: String?

    private var pollingTask: Task<Void, Never>?

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() async {
        do {
            let client = try AcpmClient.fromDefaultDiscovery(caller: "acpm-console")
            async let statusTask = client.systemStatus()
            async let modelsTask = client.models()
            async let failuresTask = client.recentFailures()

            let (nextStatus, nextModels, nextFailures) = try await (statusTask, modelsTask, failuresTask)
            self.status = nextStatus
            self.models = nextModels
            self.recentFailures = nextFailures
            self.connected = true
            self.lastErrorMessage = nil

            self.memoryHistoryMB.append(nextStatus.used.totalMB)
            if self.memoryHistoryMB.count > 60 {
                self.memoryHistoryMB.removeFirst()
            }
        } catch {
            self.connected = false
            self.lastErrorMessage = error.localizedDescription
        }
    }

    func loadModel(_ id: String) async {
        guard let client = try? AcpmClient.fromDefaultDiscovery(caller: "acpm-console") else { return }
        _ = try? await client.loadModel(id)
        await refresh()
    }

    func unloadModel(_ id: String) async {
        guard let client = try? AcpmClient.fromDefaultDiscovery(caller: "acpm-console") else { return }
        _ = try? await client.unloadModel(id)
        await refresh()
    }

    func unloadAll() async {
        guard let client = try? AcpmClient.fromDefaultDiscovery(caller: "acpm-console") else { return }
        try? await client.unloadAll()
        await refresh()
    }
}

import AcpmClient
import AppKit
import Foundation

public struct DaemonLaunchSpec: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL?
    public let sourceDescription: String

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL? = nil,
        sourceDescription: String
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.sourceDescription = sourceDescription
    }
}

public final class DaemonSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var managedProcess: Process?
    private var sleepObserver: NSObjectProtocol?

    public init() {}

    public var isManagedByApp: Bool {
        lock.withLock { managedProcess?.isRunning == true }
    }

    private func setManagedProcess(_ proc: Process?) {
        lock.withLock { managedProcess = proc }
    }

    public static func resolveDaemonLaunchSpec(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> DaemonLaunchSpec? {
        let fm = FileManager.default

        if let execURL = bundle.executableURL {
            let contentsDir = execURL.deletingLastPathComponent().deletingLastPathComponent()
            let bundledDaemon = contentsDir.appendingPathComponent("Helpers/acpmd")
            if fm.isExecutableFile(atPath: bundledDaemon.path) {
                var args = ["--headless", "--port", "18790", "--mdns-host", "acpm.local"]
                let registry = contentsDir.appendingPathComponent("Resources/default-registry.json")
                if fm.isReadableFile(atPath: registry.path) {
                    args += ["--registry", registry.path]
                }
                let mlxWorker = contentsDir.appendingPathComponent("Helpers/acpm-worker-mlx")
                if fm.isExecutableFile(atPath: mlxWorker.path) {
                    args += ["--worker-mlx-bin", mlxWorker.path]
                }
                let speechWorker = contentsDir.appendingPathComponent("Helpers/acpm-worker-speech")
                if fm.isExecutableFile(atPath: speechWorker.path) {
                    args += ["--worker-speech-bin", speechWorker.path]
                }
                appendEnvModelOverrides(from: environment, to: &args, fm: fm)
                return DaemonLaunchSpec(
                    executableURL: bundledDaemon,
                    arguments: args,
                    workingDirectoryURL: contentsDir,
                    sourceDescription: "AcpmRuntime.app/Contents/Helpers/acpmd"
                )
            }
        }

        var searchRoots: [URL] = []
        searchRoots.append(URL(fileURLWithPath: currentDirectoryPath))
        var cursor = URL(fileURLWithPath: currentDirectoryPath)
        for _ in 0..<4 {
            cursor.deleteLastPathComponent()
            searchRoots.append(cursor)
        }
        if let execURL = bundle.executableURL {
            var execCursor = execURL.deletingLastPathComponent()
            for _ in 0..<6 {
                searchRoots.append(execCursor)
                execCursor.deleteLastPathComponent()
            }
        }

        for root in searchRoots {
            let startScript = root.appendingPathComponent("scripts/start-acpmd.sh")
            if fm.isExecutableFile(atPath: startScript.path) {
                return DaemonLaunchSpec(
                    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["bash", startScript.path, "--headless"],
                    workingDirectoryURL: root,
                    sourceDescription: "scripts/start-acpmd.sh"
                )
            }
        }

        for root in searchRoots {
            for rel in ["core/target/release/acpmd", "core/target/debug/acpmd"] {
                let candidate = root.appendingPathComponent(rel)
                if fm.isExecutableFile(atPath: candidate.path) {
                    var args = ["--headless"]
                    appendEnvModelOverrides(from: environment, to: &args, fm: fm)
                    return DaemonLaunchSpec(
                        executableURL: candidate,
                        arguments: args,
                        workingDirectoryURL: root,
                        sourceDescription: rel
                    )
                }
            }
        }

        return nil
    }

    private static func appendEnvModelOverrides(
        from environment: [String: String],
        to args: inout [String],
        fm: FileManager
    ) {
        let pairs: [(String, String)] = [
            ("ACPM_LLM_DIR", "yanmo-correct-4b-cot"),
            ("ACPM_ASR_DIR", "qwen3-asr-1.7b"),
            ("ACPM_TTS_DIR", "qwen3-tts-1.7b"),
            ("ACPM_VAD_DIR", "speech-vad-pyannote"),
        ]
        for (envKey, modelId) in pairs {
            if let dir = environment[envKey], !dir.isEmpty, fm.fileExists(atPath: dir) {
                args += ["--model-path", "\(modelId)=\(dir)"]
            }
        }
    }

    public func ensureRunning() async -> String? {
        if await isExistingDaemonHealthy() {
            return nil
        }
        guard let spec = Self.resolveDaemonLaunchSpec() else {
            return "未找到 acpmd 可执行文件，请先运行打包脚本或 scripts/start-acpmd.sh。"
        }

        let proc = Process()
        proc.executableURL = spec.executableURL
        proc.arguments = spec.arguments
        proc.currentDirectoryURL = spec.workingDirectoryURL
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            setManagedProcess(proc)
        } catch {
            return "启动 acpmd 失败（\(spec.sourceDescription)）：\(error.localizedDescription)"
        }

        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(350))
            if await isExistingDaemonHealthy() {
                return nil
            }
            if !proc.isRunning {
                return "acpmd 启动后提前退出（状态码 \(proc.terminationStatus)）。"
            }
        }
        return "等待 acpmd HTTP 服务就绪超时。"
    }

    public func stopManagedDaemonIfOwned() {
        let proc: Process? = lock.withLock {
            let p = managedProcess
            managedProcess = nil
            return p
        }

        guard let proc, proc.isRunning else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(3.0)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    public func registerSleepHandler(_ onSleep: @escaping @Sendable () async -> Void) {
        let alreadyRegistered = lock.withLock { sleepObserver != nil }
        guard !alreadyRegistered else { return }

        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                await onSleep()
            }
        }
        lock.withLock { sleepObserver = observer }
    }

    private func isExistingDaemonHealthy() async -> Bool {
        guard let client = try? AcpmClient.fromDefaultDiscovery(caller: "acpm-console-probe") else {
            return false
        }
        return (try? await client.health()) != nil
    }
}

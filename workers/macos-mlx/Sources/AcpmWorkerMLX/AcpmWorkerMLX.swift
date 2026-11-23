import EngineASR
import EngineLLM
import EngineTTS
import Foundation
import WorkerCore

@main
struct AcpmWorkerMLXEntry {
    static func main() async {
        do {
            let options = try WorkerCLIOptions.parse(arguments: CommandLine.arguments)
            if options.showHelp {
                printUsage()
                return
            }

            WorkerFrameEmitter.emit(.stateFrame(.starting, ipcEndpoint: options.ipcPath))

            if options.probe {
                WorkerFrameEmitter.emit(
                    .stateFrame(
                        .warm,
                        modelLoadMs: 0.0,
                        memory: WorkerMemorySnapshot(unifiedMB: 0),
                        ipcEndpoint: options.ipcPath
                    )
                )
                return
            }

            guard let modelDirPath = options.modelDir else {
                WorkerFrameEmitter.emit(
                    .errorFrame(stage: "WORKER_START", detail: "MISSING_MODEL_DIR", fatal: true)
                )
                Foundation.exit(2)
            }

            let engine: any InferenceEngine = switch options.mode {
            case .llm: MLXLLMEngine(modelId: options.modelId)
            case .asr: MLXASREngine(modelId: options.modelId)
            case .tts: MLXTTSEngine(modelId: options.modelId)
            }

            WorkerFrameEmitter.emit(.stateFrame(.loading))
            let loadMs = try await engine.load(from: URL(fileURLWithPath: modelDirPath))
            WorkerFrameEmitter.emit(
                .stateFrame(
                    .warm,
                    modelLoadMs: loadMs,
                    memory: WorkerMemorySnapshot(unifiedMB: 0),
                    ipcEndpoint: options.ipcPath
                )
            )

            // Parent death / EOF self-termination invariant.
            while let rawLine = readLine(strippingNewline: true) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let data = trimmed.data(using: .utf8),
                      let cmd = try? JSONDecoder().decode(WorkerCommand.self, from: data)
                else {
                    continue
                }
                switch cmd.cmd {
                case .trimCache:
                    await engine.trimCaches()
                case .shutdown:
                    WorkerFrameEmitter.emit(.stateFrame(.unloading))
                    await engine.unload()
                    return
                }
            }

            WorkerFrameEmitter.emit(.stateFrame(.unloading))
            await engine.unload()
        } catch {
            WorkerFrameEmitter.emit(
                .errorFrame(stage: "WORKER_START", detail: String(describing: error), fatal: true)
            )
            Foundation.exit(1)
        }
    }

    private static func printUsage() {
        print("Usage: acpm-worker-mlx --mode <llm|asr|tts> --model-id <id> [--model-dir <path>] [--ipc-path <sock>] [--probe]")
    }
}

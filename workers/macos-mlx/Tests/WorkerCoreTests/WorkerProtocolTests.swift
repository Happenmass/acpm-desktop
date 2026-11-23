import EngineTTS
import Foundation
import Testing
import WorkerCore

struct WorkerProtocolTests {
    @Test func frameEncodingUsesProtocolPrefix() throws {
        let frame = WorkerFrameEnvelope.stateFrame(
            .warm,
            tsMs: 1234,
            modelLoadMs: 42.5,
            memory: WorkerMemorySnapshot(unifiedMB: 2950),
            ipcEndpoint: "/tmp/test.sock"
        )
        let line = try WorkerFrameEmitter.encodeLine(frame)
        #expect(line.hasPrefix(WorkerFrameEmitter.prefix))
        let jsonPart = String(line.dropFirst(WorkerFrameEmitter.prefix.count))
        let decoded = try JSONDecoder().decode(WorkerFrameEnvelope.self, from: Data(jsonPart.utf8))
        #expect(decoded.state == .warm)
        #expect(decoded.memory?.unifiedMB == 2950)
    }

    @Test func cliOptionsParsesModeAndProbe() throws {
        let opts = try WorkerCLIOptions.parse(arguments: [
            "acpm-worker-mlx",
            "--mode", "tts",
            "--model-id", "qwen3-tts-1.7b",
            "--probe",
        ])
        #expect(opts.mode == .tts)
        #expect(opts.modelId == "qwen3-tts-1.7b")
        #expect(opts.probe)
    }

    @Test func voicePromptCacheKeyDeterministic() {
        let a = VoicePromptCacheKey(
            modelId: "qwen3-tts-1.7b",
            referenceAudioSHA256: "abc",
            referenceText: "你好",
            xVectorOnly: false
        )
        let b = VoicePromptCacheKey(
            modelId: "qwen3-tts-1.7b",
            referenceAudioSHA256: "abc",
            referenceText: "你好",
            xVectorOnly: false
        )
        let c = VoicePromptCacheKey(
            modelId: "qwen3-tts-1.7b",
            referenceAudioSHA256: "abc",
            referenceText: "你好!",
            xVectorOnly: false
        )
        #expect(a == b)
        #expect(a != c)
    }
}

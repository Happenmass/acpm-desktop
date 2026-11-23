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

    @Test func processMemoryReadsPositivePhysicalFootprint() {
        let bytes = ProcessMemory.physFootprintBytes()
        #expect(bytes > 0)
    }

    @Test func wavWriterProducesValidPCM16Header() throws {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
        let wavData = WAVWriter.encodePCM16MonoData(samples: samples, sampleRate: 24_000)
        #expect(wavData.count == 44 + samples.count * 2)
        #expect(String(data: wavData.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wavData[8..<12], encoding: .ascii) == "WAVE")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("acpm-wav-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let written = try WAVWriter.writePCM16Mono(samples: samples, sampleRate: 24_000, to: tmp)
        #expect(written == wavData.count)
    }

    @Test func cotSplitterAndHostValidationWork() {
        let split1 = CotSplitter.split(
            rawText: "<think>北静应为北京</think>\n\n明天去北京。",
            enabled: true
        )
        #expect(split1.reasoning == "北静应为北京")
        #expect(split1.content == "明天去北京。")

        let splitPrefilled = CotSplitter.split(
            rawText: "思考内容\n</think>\n\n正文",
            enabled: true,
            startsInThink: true
        )
        #expect(splitPrefilled.reasoning == "思考内容")
        #expect(splitPrefilled.content == "正文")

        #expect(WorkerHTTPServer.isAllowedHostHeader("127.0.0.1:18790", mdnsHost: "acpm.local", activeLanIP: "192.168.1.50"))
        #expect(WorkerHTTPServer.isAllowedHostHeader("acpm.local:18790", mdnsHost: "acpm.local", activeLanIP: "192.168.1.50"))
        #expect(WorkerHTTPServer.isAllowedHostHeader("192.168.1.50:18790", mdnsHost: "acpm.local", activeLanIP: "192.168.1.50"))
        #expect(!WorkerHTTPServer.isAllowedHostHeader("evil.example:18790", mdnsHost: "acpm.local", activeLanIP: "192.168.1.50"))
    }
}

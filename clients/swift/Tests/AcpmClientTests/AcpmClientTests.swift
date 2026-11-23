import AcpmClient
import Foundation
import Testing

struct AcpmClientTests {
    @Test func decodesRuntimeDiscoveryAndApiError() throws {
        let discoveryJSON = """
        {
          "version": 1,
          "pid": 12345,
          "started_at": "2026-11-23T12:40:00Z",
          "http_base_url": "http://127.0.0.1:18790",
          "native_ipc_path": "/tmp/daemon.sock",
          "token": "secret",
          "platform": "darwin-arm64",
          "capabilities": ["llm", "asr", "tts"]
        }
        """
        let discovery = try JSONDecoder().decode(RuntimeDiscovery.self, from: Data(discoveryJSON.utf8))
        #expect(discovery.pid == 12345)
        #expect(discovery.baseURL?.absoluteString == "http://127.0.0.1:18790")

        let errorJSON = """
        {
          "error": {
            "code": "MODEL_NOT_INSTALLED",
            "message": "Missing model",
            "request_id": "req-1",
            "stage": "MODEL_PREPARE",
            "detail": "MISSING_WEIGHT_FILES",
            "native_code": null,
            "elapsed_ms": 5,
            "retryable": false
          }
        }
        """
        let envelope = try JSONDecoder().decode(ApiErrorEnvelope.self, from: Data(errorJSON.utf8))
        #expect(envelope.error.code == .modelNotInstalled)
        #expect(envelope.error.stage == "MODEL_PREPARE")
    }

    @Test func encodesVoiceCloningSpeechRequestAndDecodesReasoningResponse() throws {
        let req = SpeechRequest(
            model: "qwen3-tts-1.7b",
            input: "测试配音",
            referenceAudio: "/tmp/ref.wav",
            referenceText: "参考录音文本",
            outputPath: "/tmp/out.wav"
        )
        let encoded = try JSONEncoder().encode(req)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(jsonObject["reference_audio"] as? String == "/tmp/ref.wav")
        #expect(jsonObject["reference_text"] as? String == "参考录音文本")
        #expect(jsonObject["output_path"] as? String == "/tmp/out.wav")

        let chatJSON = """
        {
          "id": "chatcmpl-1",
          "object": "chat.completion",
          "created": 1763872800,
          "model": "yanmo-correct-4b-cot",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "reasoning_content": "纠错思考",
                "content": "纠错结果"
              },
              "finish_reason": "stop"
            }
          ]
        }
        """
        let chat = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(chatJSON.utf8))
        #expect(chat.choices.first?.message.reasoningContent == "纠错思考")
        #expect(chat.choices.first?.message.content == "纠错结果")
    }
}

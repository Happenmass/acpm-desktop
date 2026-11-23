import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from email.message import Message
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from acpm_client import AcpmClient, AcpmError, discover_runtime


class FakeResponse:
    def __init__(self, body: bytes, content_type: str = "application/json") -> None:
        self._body = body
        self.headers = Message()
        self.headers["Content-Type"] = content_type

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


class FakeOpener:
    def __init__(self, handler) -> None:
        self.handler = handler
        self.requests = []

    def open(self, req, timeout=None):
        self.requests.append((req, timeout))
        return self.handler(req)


class AcpmClientTests(unittest.TestCase):
    def test_discover_runtime_validates_live_pid(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runtime_path = Path(tmp) / "runtime.json"
            runtime_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "pid": os.getpid(),
                        "started_at": "2026-11-23T12:40:00Z",
                        "http_base_url": "http://127.0.0.1:18790/",
                        "native_ipc_path": "/tmp/daemon.sock",
                        "token": "tok_123",
                        "platform": "darwin-arm64",
                        "capabilities": ["llm", "asr", "tts"],
                        "mdns_hostname": "acpm.local",
                        "mdns_base_url": "http://acpm.local:18790/",
                    }
                ),
                encoding="utf-8",
            )
            info = discover_runtime(tmp)
            self.assertEqual(info.http_base_url, "http://127.0.0.1:18790")
            self.assertEqual(info.token, "tok_123")
            self.assertEqual(info.mdns_hostname, "acpm.local")
            self.assertEqual(info.mdns_base_url, "http://acpm.local:18790")

            mdns_client = AcpmClient.from_mdns("tok_123", host="acpm.local.", port=18790)
            self.assertEqual(mdns_client.base_url, "http://acpm.local:18790")

    def test_speech_voice_cloning_and_headers(self) -> None:
        def handler(req):
            return FakeResponse(
                json.dumps(
                    {
                        "output_path": "/tmp/out.wav",
                        "bytes": 240044,
                        "sample_rate": 24000,
                        "duration_ms": 5000,
                        "voice_cache_hit": True,
                    }
                ).encode("utf-8")
            )

        opener = FakeOpener(handler)
        client = AcpmClient("http://127.0.0.1:18790", "secret", caller="video-agent", opener=opener)
        res = client.speech(
            "第一句配音",
            reference_audio="/tmp/ref.wav",
            reference_text="参考台词",
            output_path="/tmp/out.wav",
            priority="batch",
        )
        self.assertIsInstance(res, dict)
        self.assertTrue(res["voice_cache_hit"])

        req, _ = opener.requests[0]
        self.assertEqual(req.get_header("Authorization"), "Bearer secret")
        self.assertEqual(req.get_header("X-ai-priority"), "batch")
        self.assertEqual(req.get_header("X-ai-caller"), "video-agent")
        body = json.loads(req.data.decode("utf-8"))
        self.assertEqual(body["reference_audio"], "/tmp/ref.wav")
        self.assertEqual(body["reference_text"], "参考台词")
        self.assertEqual(body["output_path"], "/tmp/out.wav")

    def test_structured_error_decoding(self) -> None:
        def handler(req):
            err_body = json.dumps(
                {
                    "error": {
                        "code": "INSUFFICIENT_MEMORY",
                        "message": "Budget exceeded",
                        "request_id": "req-42",
                        "stage": "SCHEDULER_QUEUE",
                        "detail": "UNIFIED_MEMORY_FULL",
                        "native_code": None,
                        "elapsed_ms": 11,
                        "retryable": True,
                    }
                }
            ).encode("utf-8")
            raise urllib.error.HTTPError(
                req.full_url, 507, "Insufficient Storage", Message(), io.BytesIO(err_body)
            )

        client = AcpmClient("http://127.0.0.1:18790", "secret", opener=FakeOpener(handler))
        with self.assertRaises(AcpmError) as ctx:
            client.chat_completions([{"role": "user", "content": "测试"}], prompt_cache_key="k1")

        self.assertEqual(ctx.exception.code, "INSUFFICIENT_MEMORY")
        self.assertEqual(ctx.exception.stage, "SCHEDULER_QUEUE")
        self.assertEqual(ctx.exception.request_id, "req-42")
        self.assertTrue(ctx.exception.retryable)

    def test_vad_voice_library_and_speech_batch_apis(self) -> None:
        calls: list[tuple[str, str, dict | None]] = []

        def handler(req):
            path = req.full_url.removeprefix("http://127.0.0.1:18790")
            body = json.loads(req.data.decode("utf-8")) if req.data else None
            calls.append((req.get_method(), path, body))
            if path == "/v1/audio/vad":
                return FakeResponse(
                    json.dumps(
                        {"segments": [{"start_ms": 100, "end_ms": 1400}], "duration_ms": 1500}
                    ).encode("utf-8")
                )
            if req.get_method() == "POST" and path == "/v1/audio/voices":
                return FakeResponse(
                    json.dumps(
                        {
                            "voice_id": "v_abc",
                            "name": "Alice",
                            "reference_text": "hello",
                            "language": "en",
                            "notes": "bright",
                            "duration_ms": 1200,
                            "sha256": "deadbeef",
                            "created_at": "2026-11-23T12:00:00Z",
                        }
                    ).encode("utf-8")
                )
            if path == "/v1/audio/voices":
                return FakeResponse(
                    json.dumps({"voices": [{"voice_id": "v_abc", "name": "Alice"}]}).encode(
                        "utf-8"
                    )
                )
            if path == "/v1/audio/voices/v_abc/sample":
                return FakeResponse(b"RIFF....WAVEfmt ", content_type="audio/wav")
            if path == "/v1/audio/voices/v_abc" and req.get_method() == "GET":
                return FakeResponse(
                    json.dumps({"voice_id": "v_abc", "name": "Alice"}).encode("utf-8")
                )
            if path == "/v1/audio/voices/v_abc" and req.get_method() == "DELETE":
                return FakeResponse(b"")
            if req.get_method() == "POST" and path == "/v1/audio/speech/batches":
                return FakeResponse(
                    json.dumps(
                        {"batch_id": "sb_1", "status": "queued", "total": 2, "completed": 0}
                    ).encode("utf-8")
                )
            if path == "/v1/audio/speech/batches":
                return FakeResponse(
                    json.dumps({"batches": [{"batch_id": "sb_1", "status": "running"}]}).encode(
                        "utf-8"
                    )
                )
            return FakeResponse(
                json.dumps({"batch_id": "sb_1", "status": "paused"}).encode("utf-8")
            )

        opener = FakeOpener(handler)
        client = AcpmClient("http://127.0.0.1:18790", "secret", caller="ime", opener=opener)

        vad = client.vad("/tmp/a.wav", min_speech_ms=250, min_silence_ms=500)
        self.assertEqual(vad["segments"], [{"start_ms": 100, "end_ms": 1400}])

        voice = client.register_voice(
            "Alice", "/tmp/ref.wav", reference_text="hello", language="en", notes="bright"
        )
        self.assertEqual(voice["voice_id"], "v_abc")
        self.assertEqual(len(client.list_voices()), 1)
        self.assertEqual(client.get_voice("v_abc")["name"], "Alice")
        self.assertTrue(client.download_voice_sample("v_abc").startswith(b"RIFF"))
        client.delete_voice("v_abc")

        batch = client.create_speech_batch(
            "/tmp/out",
            [
                {"id": "1", "text": "one", "output_file": "1.wav"},
                {"id": "2", "text": "two", "output_file": "2.wav"},
            ],
            voice="v_abc",
        )
        self.assertEqual(batch["batch_id"], "sb_1")
        self.assertEqual(len(client.list_speech_batches()), 1)
        self.assertEqual(client.get_speech_batch("sb_1")["status"], "paused")
        self.assertEqual(client.pause_speech_batch("sb_1")["status"], "paused")
        self.assertEqual(client.resume_speech_batch("sb_1")["status"], "paused")
        self.assertEqual(client.cancel_speech_batch("sb_1")["status"], "paused")

        self.assertEqual(calls[0][0:2], ("POST", "/v1/audio/vad"))
        self.assertEqual(calls[1][2]["notes"], "bright")
        self.assertEqual(calls[-1][0:2], ("POST", "/v1/audio/speech/batches/sb_1/cancel"))

    def test_system_config_and_model_download_apis(self) -> None:
        calls: list[tuple[str, str, dict | None]] = []

        def handler(req):
            path = req.full_url.removeprefix("http://127.0.0.1:18790")
            body = json.loads(req.data.decode("utf-8")) if req.data else None
            calls.append((req.get_method(), path, body))
            if path == "/v1/system/config":
                return FakeResponse(json.dumps({"budget_tier": "eco"}).encode("utf-8"))
            if path == "/v1/models/yanmo-correct-4b-cot/config":
                return FakeResponse(
                    json.dumps({"id": "yanmo-correct-4b-cot", "pin_policy": "pinned"}).encode(
                        "utf-8"
                    )
                )
            if path == "/v1/models/downloads":
                return FakeResponse(
                    json.dumps({"downloads": [{"model_id": "qwen3-asr-0.6b", "status": "completed"}]}).encode(
                        "utf-8"
                    )
                )
            if path.startswith("/v1/models/qwen3-asr-0.6b/download"):
                return FakeResponse(
                    json.dumps({"model_id": "qwen3-asr-0.6b", "status": "queued"}).encode("utf-8")
                )
            return FakeResponse(b"")

        client = AcpmClient("http://127.0.0.1:18790", "secret", opener=FakeOpener(handler))
        self.assertEqual(client.update_system_config(budget_tier="eco")["budget_tier"], "eco")
        self.assertEqual(
            client.update_model_config("yanmo-correct-4b-cot", pin_policy="pinned")["pin_policy"],
            "pinned",
        )
        self.assertEqual(client.start_model_download("qwen3-asr-0.6b", quant="4bit")["status"], "queued")
        self.assertEqual(len(client.list_downloads()), 1)
        self.assertEqual(client.cancel_model_download("qwen3-asr-0.6b")["status"], "queued")
        client.delete_model("qwen3-asr-0.6b", quant="4bit")
        self.assertEqual(calls[-1][0:2], ("DELETE", "/v1/models/qwen3-asr-0.6b?quant=4bit"))


if __name__ == "__main__":
    unittest.main()

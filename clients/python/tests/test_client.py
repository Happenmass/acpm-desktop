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
                    }
                ),
                encoding="utf-8",
            )
            info = discover_runtime(tmp)
            self.assertEqual(info.http_base_url, "http://127.0.0.1:18790")
            self.assertEqual(info.token, "tok_123")

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


if __name__ == "__main__":
    unittest.main()

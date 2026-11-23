from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class RuntimeDiscovery:
    version: int
    pid: int
    started_at: str
    http_base_url: str
    native_ipc_path: str
    token: str
    platform: str
    capabilities: list[str]
    mdns_hostname: str | None = None
    mdns_base_url: str | None = None


class AcpmError(RuntimeError):
    def __init__(
        self,
        code: str,
        message: str,
        request_id: str,
        stage: str,
        detail: str,
        native_code: str | None = None,
        elapsed_ms: int = 0,
        retryable: bool = False,
        http_status: int = 500,
    ) -> None:
        super().__init__(f"[{code}] {stage}/{detail}: {message} (request_id={request_id})")
        self.code = code
        self.message = message
        self.request_id = request_id
        self.stage = stage
        self.detail = detail
        self.native_code = native_code
        self.elapsed_ms = elapsed_ms
        self.retryable = retryable
        self.http_status = http_status


def default_data_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "acpm-desktop"
    if sys.platform.startswith("win"):
        local_app_data = os.environ.get("LOCALAPPDATA")
        base = Path(local_app_data) if local_app_data else Path.home() / "AppData" / "Local"
        return base / "acpm-desktop"
    return Path.home() / ".local" / "share" / "acpm-desktop"


def _is_pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "posix":
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
    return True


def discover_runtime(
    data_dir: str | Path | None = None,
    *,
    verify_alive: bool = True,
) -> RuntimeDiscovery:
    base = Path(data_dir) if data_dir is not None else default_data_dir()
    runtime_file = base / "runtime.json"
    raw = json.loads(runtime_file.read_text(encoding="utf-8"))
    info = RuntimeDiscovery(
        version=int(raw["version"]),
        pid=int(raw["pid"]),
        started_at=str(raw["started_at"]),
        http_base_url=str(raw["http_base_url"]).rstrip("/"),
        native_ipc_path=str(raw["native_ipc_path"]),
        token=str(raw["token"]),
        platform=str(raw["platform"]),
        capabilities=[str(x) for x in raw.get("capabilities", [])],
        mdns_hostname=raw.get("mdns_hostname"),
        mdns_base_url=str(raw["mdns_base_url"]).rstrip("/") if raw.get("mdns_base_url") else None,
    )
    if verify_alive and not _is_pid_alive(info.pid):
        raise ProcessLookupError(f"Stale runtime.json points to dead pid {info.pid}")
    return info


class AcpmClient:
    """Zero-dependency HTTP client for acpm-desktop suitable for Python workflows and Agents."""

    def __init__(
        self,
        base_url: str,
        token: str,
        *,
        caller: str = "python-client",
        timeout_sec: float = 120.0,
        opener: urllib.request.OpenerDirector | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.caller = caller
        self.timeout_sec = timeout_sec
        self._opener = opener or urllib.request.build_opener()

    @classmethod
    def from_default_discovery(
        cls,
        *,
        data_dir: str | Path | None = None,
        caller: str = "python-client",
        timeout_sec: float = 120.0,
    ) -> AcpmClient:
        info = discover_runtime(data_dir=data_dir)
        return cls(info.http_base_url, info.token, caller=caller, timeout_sec=timeout_sec)

    @classmethod
    def from_mdns(
        cls,
        token: str,
        *,
        host: str = "acpm.local",
        port: int = 18790,
        caller: str = "python-client",
        timeout_sec: float = 120.0,
        opener: urllib.request.OpenerDirector | None = None,
    ) -> AcpmClient:
        normalized_host = host.strip().rstrip(".")
        return cls(
            f"http://{normalized_host}:{port}",
            token,
            caller=caller,
            timeout_sec=timeout_sec,
            opener=opener,
        )

    def health(self) -> dict[str, Any]:
        return self._request_json("GET", "/healthz", authenticated=False)

    def models(self) -> list[dict[str, Any]]:
        return list(self._request_json("GET", "/v1/models").get("models", []))

    def system_status(self) -> dict[str, Any]:
        return self._request_json("GET", "/v1/system/status")

    def recent_failures(self) -> list[dict[str, Any]]:
        return list(self._request_json("GET", "/v1/system/failures").get("failures", []))

    def load_model(self, model_id: str) -> dict[str, Any]:
        return self._request_json("POST", f"/v1/models/{model_id}/load", payload={})

    def unload_model(self, model_id: str) -> dict[str, Any]:
        return self._request_json("POST", f"/v1/models/{model_id}/unload", payload={})

    def prewarm(self, models: list[str], prompt_cache_keys: list[str] | None = None) -> dict[str, Any]:
        body: dict[str, Any] = {"models": models}
        if prompt_cache_keys is not None:
            body["prompt_cache_keys"] = prompt_cache_keys
        return self._request_json("POST", "/v1/models/prewarm", payload=body)

    def system_config(self) -> dict[str, Any]:
        return self._request_json("GET", "/v1/system/config")

    def update_system_config(
        self,
        *,
        budget_tier: str | None = None,
        budget_override_mb: int | None = None,
        clear_budget_override: bool = False,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"clear_budget_override": clear_budget_override}
        if budget_tier is not None:
            payload["budget_tier"] = budget_tier
        if budget_override_mb is not None:
            payload["budget_override_mb"] = budget_override_mb
        return self._request_json("PATCH", "/v1/system/config", payload=payload)

    def update_model_config(
        self,
        model_id: str,
        *,
        pin_policy: str | None = None,
        idle_timeout_sec: int | None = None,
        quant: str | None = None,
        path: str | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {}
        if pin_policy is not None:
            payload["pin_policy"] = pin_policy
        if idle_timeout_sec is not None:
            payload["idle_timeout_sec"] = idle_timeout_sec
        if quant is not None:
            payload["quant"] = quant
        if path is not None:
            payload["path"] = path
        return self._request_json("PATCH", f"/v1/models/{model_id}/config", payload=payload)

    def list_downloads(self) -> list[dict[str, Any]]:
        return list(self._request_json("GET", "/v1/models/downloads").get("downloads", []))

    def start_model_download(self, model_id: str, *, quant: str | None = None) -> dict[str, Any]:
        payload: dict[str, Any] = {}
        if quant is not None:
            payload["quant"] = quant
        return self._request_json("POST", f"/v1/models/{model_id}/download", payload=payload)

    def get_model_download(self, model_id: str) -> dict[str, Any]:
        return self._request_json("GET", f"/v1/models/{model_id}/download")

    def cancel_model_download(self, model_id: str) -> dict[str, Any]:
        return self._request_json("POST", f"/v1/models/{model_id}/download/cancel", payload={})

    def delete_model(self, model_id: str, *, quant: str | None = None) -> None:
        path = f"/v1/models/{model_id}"
        if quant is not None:
            path += f"?quant={urllib.parse.quote(quant)}"
        self._request_raw("DELETE", path)

    def unload_all(self, *, include_pinned: bool = False) -> dict[str, Any]:
        return self._request_json(
            "POST", "/v1/system/unload-all", payload={"include_pinned": include_pinned}
        )

    def chat_completions(
        self,
        messages: list[dict[str, str]],
        *,
        model: str = "yanmo-correct-4b-cot",
        separate_reasoning: bool = True,
        prompt_cache_key: str | None = None,
        temperature: float = 0.0,
        max_tokens: int = 512,
        priority: str = "interactive",
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": model,
            "messages": messages,
            "stream": False,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "separate_reasoning": separate_reasoning,
        }
        if prompt_cache_key is not None:
            payload["prompt_cache_key"] = prompt_cache_key
        return self._request_json("POST", "/v1/chat/completions", payload=payload, priority=priority)

    def transcribe(
        self,
        file_path: str,
        *,
        model: str = "qwen3-asr-0.6b",
        language: str = "auto",
        vad_filter: bool = True,
        timestamps: bool = True,
        prompt: str | None = None,
        priority: str = "normal",
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": model,
            "file_path": file_path,
            "language": language,
            "vad_filter": vad_filter,
            "timestamps": timestamps,
        }
        if prompt is not None:
            payload["prompt"] = prompt
        return self._request_json("POST", "/v1/audio/transcriptions", payload=payload, priority=priority)

    def speech(
        self,
        input_text: str,
        *,
        model: str = "qwen3-tts-1.7b",
        voice: str | None = None,
        instruct: str | None = None,
        reference_audio: str | None = None,
        reference_text: str | None = None,
        x_vector_only_mode: bool = False,
        speed: float = 1.0,
        response_format: str = "wav",
        output_path: str | None = None,
        priority: str = "batch",
    ) -> dict[str, Any] | bytes:
        payload: dict[str, Any] = {
            "model": model,
            "input": input_text,
            "x_vector_only_mode": x_vector_only_mode,
            "speed": speed,
            "response_format": response_format,
        }
        if voice is not None:
            payload["voice"] = voice
        if instruct is not None:
            payload["instruct"] = instruct
        if reference_audio is not None:
            payload["reference_audio"] = reference_audio
        if reference_text is not None:
            payload["reference_text"] = reference_text
        if output_path is not None:
            payload["output_path"] = output_path

        raw, content_type = self._request_raw("POST", "/v1/audio/speech", payload=payload, priority=priority)
        if output_path is not None or "application/json" in content_type:
            return json.loads(raw.decode("utf-8"))
        return raw

    def register_voice(
        self,
        name: str,
        reference_audio: str,
        *,
        reference_text: str | None = None,
        language: str | None = None,
        notes: str | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"name": name, "reference_audio": reference_audio}
        if reference_text is not None:
            payload["reference_text"] = reference_text
        if language is not None:
            payload["language"] = language
        if notes is not None:
            payload["notes"] = notes
        return self._request_json("POST", "/v1/audio/voices", payload=payload)

    def list_voices(self) -> list[dict[str, Any]]:
        return list(self._request_json("GET", "/v1/audio/voices").get("voices", []))

    def get_voice(self, voice_id: str) -> dict[str, Any]:
        return self._request_json("GET", f"/v1/audio/voices/{voice_id}")

    def download_voice_sample(self, voice_id: str) -> bytes:
        raw, _ = self._request_raw("GET", f"/v1/audio/voices/{voice_id}/sample")
        return raw

    def delete_voice(self, voice_id: str) -> None:
        self._request_raw("DELETE", f"/v1/audio/voices/{voice_id}")

    def create_speech_batch(
        self,
        output_dir: str,
        items: list[dict[str, Any]],
        *,
        model: str = "qwen3-tts-1.7b",
        voice: str | None = None,
        instruct: str | None = None,
        reference_audio: str | None = None,
        reference_text: str | None = None,
        x_vector_only_mode: bool = False,
        speed: float | None = None,
        priority: str = "batch",
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": model,
            "output_dir": output_dir,
            "items": items,
            "x_vector_only_mode": x_vector_only_mode,
        }
        if voice is not None:
            payload["voice"] = voice
        if instruct is not None:
            payload["instruct"] = instruct
        if reference_audio is not None:
            payload["reference_audio"] = reference_audio
        if reference_text is not None:
            payload["reference_text"] = reference_text
        if speed is not None:
            payload["speed"] = speed
        return self._request_json(
            "POST", "/v1/audio/speech/batches", payload=payload, priority=priority
        )

    def list_speech_batches(self) -> list[dict[str, Any]]:
        return list(
            self._request_json("GET", "/v1/audio/speech/batches").get("batches", [])
        )

    def get_speech_batch(self, batch_id: str) -> dict[str, Any]:
        return self._request_json("GET", f"/v1/audio/speech/batches/{batch_id}")

    def pause_speech_batch(self, batch_id: str) -> dict[str, Any]:
        return self._request_json(
            "POST", f"/v1/audio/speech/batches/{batch_id}/pause", payload={}
        )

    def resume_speech_batch(self, batch_id: str) -> dict[str, Any]:
        return self._request_json(
            "POST", f"/v1/audio/speech/batches/{batch_id}/resume", payload={}
        )

    def cancel_speech_batch(self, batch_id: str) -> dict[str, Any]:
        return self._request_json(
            "POST", f"/v1/audio/speech/batches/{batch_id}/cancel", payload={}
        )

    def vad(
        self,
        file_path: str,
        *,
        model: str = "speech-vad-pyannote",
        min_speech_ms: int | None = None,
        min_silence_ms: int | None = None,
        priority: str = "normal",
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"model": model, "file_path": file_path}
        if min_speech_ms is not None:
            payload["min_speech_ms"] = min_speech_ms
        if min_silence_ms is not None:
            payload["min_silence_ms"] = min_silence_ms
        return self._request_json("POST", "/v1/audio/vad", payload=payload, priority=priority)

    def diarize(
        self,
        file_path: str,
        *,
        model: str = "speech-speaker-eres2net",
        speaker_count: int | None = None,
        priority: str = "batch",
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"model": model, "file_path": file_path}
        if speaker_count is not None:
            payload["speaker_count"] = speaker_count
        return self._request_json("POST", "/v1/audio/diarization", payload=payload, priority=priority)

    def _request_json(
        self,
        method: str,
        path: str,
        *,
        payload: dict[str, Any] | None = None,
        priority: str = "normal",
        authenticated: bool = True,
    ) -> dict[str, Any]:
        raw, _ = self._request_raw(
            method,
            path,
            payload=payload,
            priority=priority,
            authenticated=authenticated,
        )
        return json.loads(raw.decode("utf-8")) if raw else {}

    def _request_raw(
        self,
        method: str,
        path: str,
        *,
        payload: dict[str, Any] | None = None,
        priority: str = "normal",
        authenticated: bool = True,
    ) -> tuple[bytes, str]:
        url = f"{self.base_url}{path}"
        headers = {
            "X-AI-Priority": priority,
            "X-AI-Caller": self.caller,
            "X-AI-Request-Id": str(uuid.uuid4()),
        }
        if authenticated:
            headers["Authorization"] = f"Bearer {self.token}"

        data: bytes | None = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self._opener.open(req, timeout=self.timeout_sec) as resp:
                content_type = resp.headers.get("Content-Type", "")
                return resp.read(), content_type
        except urllib.error.HTTPError as exc:
            body_bytes = exc.read()
            raise self._decode_http_error(exc.code, body_bytes) from exc

    @staticmethod
    def _decode_http_error(status: int, body_bytes: bytes) -> AcpmError:
        try:
            parsed = json.loads(body_bytes.decode("utf-8"))
            err = parsed["error"]
            return AcpmError(
                code=str(err["code"]),
                message=str(err["message"]),
                request_id=str(err["request_id"]),
                stage=str(err["stage"]),
                detail=str(err["detail"]),
                native_code=err.get("native_code"),
                elapsed_ms=int(err.get("elapsed_ms", 0)),
                retryable=bool(err.get("retryable", False)),
                http_status=status,
            )
        except Exception:
            return AcpmError(
                code="INFERENCE_FAILED",
                message=body_bytes.decode("utf-8", errors="replace") or f"HTTP {status}",
                request_id="unknown",
                stage="HTTP_ADMISSION",
                detail=f"HTTP_{status}",
                http_status=status,
            )

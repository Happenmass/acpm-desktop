#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACTS_DIR="${ROOT_DIR}/benchmarks/phase0/artifacts"
mkdir -p "${ARTIFACTS_DIR}"

LLM_DIR="${LLM_DIR:-$HOME/.cache/codex/models/yanmo-polish/2026-11-23/qwen35-4b-v6-mlx8}"
ASR_DIR="${ASR_DIR:-$HOME/.cache/huggingface/hub/models--mlx-community--Qwen3-ASR-1.7B-8bit/snapshots/a8379a2e2f9e313c9292cdf1af4055ab56d50d55}"
TTS_DIR="${TTS_DIR:-$HOME/.cache/huggingface/local-models/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16}"
CORPUS="${ROOT_DIR}/benchmarks/phase0/corpus_20_cot.json"

WORKER_BIN="${ROOT_DIR}/workers/macos-mlx/.build/release/acpm-worker-mlx"
if [[ ! -x "${WORKER_BIN}" ]]; then
    swift build -c release --package-path "${ROOT_DIR}/workers/macos-mlx" --build-system native
fi
"${ROOT_DIR}/scripts/ensure-metallib.sh" "${ROOT_DIR}/workers/macos-mlx/.build/release"

# Generate clean reference WAV and ASR input WAV if not overridden
REF_WAV="${REF_AUDIO:-${ARTIFACTS_DIR}/ref_narrator_5s.wav}"
REF_TEXT="${REF_TEXT:-大家好，欢迎收听今天的本地大模型语音推理架构技术分享。}"
if [[ ! -s "${REF_WAV}" ]]; then
    echo "[phase0] Generating 24kHz mono reference audio via macOS say..."
    AIFF_TMP="${ARTIFACTS_DIR}/ref_tmp.aiff"
    if say -v Tingting -o "${AIFF_TMP}" "${REF_TEXT}" 2>/dev/null; then
        :
    else
        say -o "${AIFF_TMP}" "${REF_TEXT}"
    fi
    afconvert -f WAVE -d LEI16@24000 -c 1 "${AIFF_TMP}" "${REF_WAV}"
    rm -f "${AIFF_TMP}"
fi

ASR_SAMPLE_WAV="${ASR_AUDIO:-${ARTIFACTS_DIR}/asr_sample_16k.wav}"
ASR_SAMPLE_TEXT="明天去北京出差，订一张早班机票，下午三点半开会讨论项目进度。"
if [[ ! -s "${ASR_SAMPLE_WAV}" ]]; then
    echo "[phase0] Generating 16kHz mono ASR sample WAV via macOS say..."
    AIFF_TMP="${ARTIFACTS_DIR}/asr_tmp.aiff"
    if say -v Tingting -o "${AIFF_TMP}" "${ASR_SAMPLE_TEXT}" 2>/dev/null; then
        :
    else
        say -o "${AIFF_TMP}" "${ASR_SAMPLE_TEXT}"
    fi
    afconvert -f WAVE -d LEI16@16000 -c 1 "${AIFF_TMP}" "${ASR_SAMPLE_WAV}"
    rm -f "${AIFF_TMP}"
fi

SWIFT_REPORT="${ARTIFACTS_DIR}/swift_report.json"
echo "[phase0] Running Swift MLX benchmark across LLM, TTS, and ASR (isolated per-model processes for clean ri_phys_footprint)..."
"${WORKER_BIN}" \
    --mode benchmark \
    --llm-dir "${LLM_DIR}" \
    --corpus "${CORPUS}" \
    --artifacts-dir "${ARTIFACTS_DIR}" \
    --out-json "${ARTIFACTS_DIR}/swift_llm.json"

"${WORKER_BIN}" \
    --mode benchmark \
    --tts-dir "${TTS_DIR}" \
    --ref-audio "${REF_WAV}" \
    --ref-text "${REF_TEXT}" \
    --artifacts-dir "${ARTIFACTS_DIR}" \
    --out-json "${ARTIFACTS_DIR}/swift_tts.json"

"${WORKER_BIN}" \
    --mode benchmark \
    --asr-dir "${ASR_DIR}" \
    --audio "${ASR_SAMPLE_WAV}" \
    --audio "${ARTIFACTS_DIR}/tts_01.wav" \
    --audio "${ARTIFACTS_DIR}/tts_02.wav" \
    --audio "${ARTIFACTS_DIR}/tts_03.wav" \
    --audio "${ARTIFACTS_DIR}/tts_04.wav" \
    --audio "${ARTIFACTS_DIR}/tts_05.wav" \
    --artifacts-dir "${ARTIFACTS_DIR}" \
    --out-json "${ARTIFACTS_DIR}/swift_asr.json"

python3 - "${ARTIFACTS_DIR}/swift_llm.json" "${ARTIFACTS_DIR}/swift_tts.json" "${ARTIFACTS_DIR}/swift_asr.json" "${SWIFT_REPORT}" <<'PY'
import json, sys
llm_j, tts_j, asr_j, out_j = sys.argv[1:5]
llm_d = json.loads(open(llm_j, encoding="utf-8").read())
tts_d = json.loads(open(tts_j, encoding="utf-8").read())
asr_d = json.loads(open(asr_j, encoding="utf-8").read())

# Attach expected_text from TTS runs onto tts_01..tts_05 ASR runs for roundtrip scoring
expected_map = {f"tts_{r['index']:02d}": r["text"] for r in tts_d.get("tts", {}).get("runs", [])}
asr_runs = asr_d.get("asr", {}).get("runs", [])
for idx, r in enumerate(asr_runs):
    if idx == 0:
        r["label"] = "audio_1"
    else:
        lbl = f"tts_{idx:02d}"
        r["label"] = lbl
        if lbl in expected_map:
            r["expected_text"] = expected_map[lbl]

merged = {
    "timestamp": llm_d.get("timestamp"),
    "metallib_path": llm_d.get("metallib_path"),
    "llm": llm_d.get("llm"),
    "tts": tts_d.get("tts"),
    "asr": asr_d.get("asr"),
}
open(out_j, "w", encoding="utf-8").write(json.dumps(merged, ensure_ascii=False, indent=2))
PY

PY_LLM_JSON="${ARTIFACTS_DIR}/py_llm.json"
echo "[phase0] Running Python mlx_lm 4B CoT baseline via uv..."
uv run --with mlx-lm python3 "${ROOT_DIR}/benchmarks/phase0/py_baseline_llm.py" \
    --model-dir "${LLM_DIR}" \
    --corpus "${CORPUS}" \
    --out-json "${PY_LLM_JSON}"

PY_ASR_JSON="${ARTIFACTS_DIR}/py_asr.json"
echo "[phase0] Attempting Python mlx_audio ASR baseline via uv..."
if ! uv run --with mlx-audio python3 "${ROOT_DIR}/benchmarks/phase0/py_baseline_asr.py" \
    --model-dir "${ASR_DIR}" \
    --audio "${ASR_SAMPLE_WAV}" \
    --swift-report "${SWIFT_REPORT}" \
    --out-json "${PY_ASR_JSON}"; then
    echo "[phase0] uv run --with mlx-audio failed; writing fallback error JSON"
    python3 -c "import json, pathlib; pathlib.Path('${PY_ASR_JSON}').write_text(json.dumps({'available': False, 'error': 'uv_mlx_audio_install_or_runtime_failed'}))"
fi

EXIT_RECLAIM_JSON="${ARTIFACTS_DIR}/exit_reclaim.json"
echo "[phase0] Running subprocess exit & memory reclamation test (Item 6)..."
python3 - "${WORKER_BIN}" "${LLM_DIR}" "${EXIT_RECLAIM_JSON}" <<'PY'
import json
import subprocess
import sys
import time

worker_bin, model_dir, out_json = sys.argv[1:4]

def vm_free_active_mb() -> dict:
    out = subprocess.check_output(["vm_stat"], text=True)
    page_size = 16384
    for line in out.splitlines():
        if "page size of" in line:
            page_size = int(line.split("page size of")[1].split("bytes")[0].strip())
    stats = {}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            v = v.strip().rstrip(".")
            if v.isdigit():
                stats[k.strip()] = int(v) * page_size // (1024 * 1024)
    return {
        "free_mb": stats.get("Pages free", 0),
        "inactive_mb": stats.get("Pages inactive", 0),
        "active_mb": stats.get("Pages active", 0),
        "wired_mb": stats.get("Pages wired down", 0),
    }

proc = subprocess.Popen(
    [worker_bin, "--mode", "llm", "--model-id", "yanmo-correct-4b-cot", "--model-dir", model_dir],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

warm_frame = None
t_start = time.perf_counter()
while True:
    line = proc.stdout.readline()
    if not line:
        break
    if line.startswith("ACPM_FRAME\t"):
        frame = json.loads(line.split("\t", 1)[1])
        if frame.get("state") == "WARM":
            warm_frame = frame
            break

load_wall_ms = round((time.perf_counter() - t_start) * 1000.0, 2)
vm_before_exit = vm_free_active_mb()

t_shutdown = time.perf_counter()
proc.stdin.write('{"cmd":"shutdown"}\n')
proc.stdin.flush()
exit_code = proc.wait(timeout=10)
exit_elapsed_ms = round((time.perf_counter() - t_shutdown) * 1000.0, 2)

time.sleep(1.0)
vm_after_1s = vm_free_active_mb()

payload = {
    "pid": proc.pid,
    "load_wall_ms": load_wall_ms,
    "warm_frame_memory_mb": (warm_frame or {}).get("memory", {}).get("unified_mb"),
    "exit_code": exit_code,
    "shutdown_to_exit_ms": exit_elapsed_ms,
    "exited_within_1s": exit_elapsed_ms < 1000.0 and exit_code == 0,
    "vm_before_exit": vm_before_exit,
    "vm_after_1s": vm_after_1s,
}
open(out_json, "w", encoding="utf-8").write(json.dumps(payload, indent=2))
print("Exit reclamation:", json.dumps(payload))
PY

SUMMARY_JSON="${ARTIFACTS_DIR}/summary.json"
echo "[phase0] Aggregating comparison summary..."
python3 "${ROOT_DIR}/benchmarks/phase0/compare_results.py" \
    --swift-report "${SWIFT_REPORT}" \
    --py-llm "${PY_LLM_JSON}" \
    --py-asr "${PY_ASR_JSON}" \
    --exit-reclaim "${EXIT_RECLAIM_JSON}" \
    --out-json "${SUMMARY_JSON}"

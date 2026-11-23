use acpm_protocol::{
    FailureStage, ResourceVector, WorkerCommand, WorkerFrame, WorkerState, FRAME_PREFIX,
};
use clap::Parser;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;

/// Cross-platform sherpa-onnx worker skeleton for Pyannote 3.0 VAD and ERes2NetV2 diarization.
/// Runs strictly on CPU threads without consuming GPU VRAM / Metal memory.
#[derive(Debug, Parser)]
#[command(name = "acpm-worker-speech", version)]
struct Args {
    #[arg(long, default_value = "speech")]
    mode: String,

    #[arg(long)]
    model_id: String,

    #[arg(long)]
    model_dir: Option<PathBuf>,

    #[arg(long)]
    ipc_path: Option<String>,

    #[arg(long, default_value = "ACPM_WORKER_TOKEN")]
    auth_token_env: String,

    #[arg(long, default_value_t = 512)]
    memory_limit_mb: u64,

    #[arg(long, default_value_t = 2)]
    threads: usize,

    #[arg(long, default_value_t = false)]
    probe: bool,
}

fn emit_frame(frame: &WorkerFrame) {
    if let Ok(json) = serde_json::to_string(frame) {
        let mut out = io::stdout().lock();
        let _ = writeln!(out, "{FRAME_PREFIX}{json}");
        let _ = out.flush();
    }
}

fn main() {
    let args = Args::parse();
    emit_frame(&WorkerFrame::State {
        state: WorkerState::Starting,
        ts_ms: 0,
        model_load_ms: None,
        memory: None,
        ipc_endpoint: args.ipc_path.clone(),
    });

    if args.probe {
        emit_frame(&WorkerFrame::State {
            state: WorkerState::Warm,
            ts_ms: 0,
            model_load_ms: Some(0.0),
            memory: Some(ResourceVector::system_and_gpu(140, 0, 0)),
            ipc_endpoint: args.ipc_path,
        });
        return;
    }

    if args.model_dir.is_none() {
        emit_frame(&WorkerFrame::Error {
            stage: FailureStage::WorkerStart,
            detail: "MISSING_MODEL_DIR".to_string(),
            native_code: None,
            fatal: true,
        });
        std::process::exit(2);
    }

    emit_frame(&WorkerFrame::State {
        state: WorkerState::Warm,
        ts_ms: 0,
        model_load_ms: Some(0.0),
        memory: Some(ResourceVector::system_and_gpu(140, 0, 0)),
        ipc_endpoint: args.ipc_path,
    });

    // Parent death / EOF self-termination invariant: exit immediately when stdin closes.
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let Ok(raw) = line else {
            break;
        };
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Ok(cmd) = serde_json::from_str::<WorkerCommand>(trimmed) {
            match cmd {
                WorkerCommand::Shutdown => break,
                WorkerCommand::TrimCache => {}
            }
        }
    }

    emit_frame(&WorkerFrame::State {
        state: WorkerState::Unloading,
        ts_ms: 0,
        model_load_ms: None,
        memory: None,
        ipc_endpoint: None,
    });
}

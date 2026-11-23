use crate::runtime_lib::resolve_onnxruntime_dylib;
use acpm_protocol::VadSegment;
use ort::environment::Environment;
use ort::session::Session;
use ort::value::Tensor;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

static ORT_ENV: OnceLock<Result<Environment, String>> = OnceLock::new();

pub(crate) fn shared_ort_environment() -> Result<Environment, String> {
    ORT_ENV
        .get_or_init(|| {
            let dylib = resolve_onnxruntime_dylib().ok_or_else(|| {
                "Could not locate libonnxruntime dylib; run scripts/ensure-sherpa-onnx.sh or set ORT_DYLIB_PATH"
                    .to_string()
            })?;
            let builder = ort::init_from(&dylib)
                .map_err(|e| format!("ort::init_from({}) failed: {e}", dylib.display()))?;
            builder
                .with_name("acpm-worker-speech")
                .build()
                .map_err(|e| format!("failed building ORT environment: {e}"))
        })
        .clone()
}

pub struct PyannoteVad {
    session: Mutex<Session>,
    window_size: usize,
    sample_rate: usize,
    window_shift: usize,
    receptive_field_size: usize,
    receptive_field_shift: usize,
    num_classes: usize,
    powerset_speech_mask: Vec<bool>,
}

impl PyannoteVad {
    pub fn load(model_path: &Path, threads: usize) -> Result<Self, String> {
        let env = shared_ort_environment()?;
        let session = Session::builder(&env)
            .map_err(|e| format!("Session::builder failed: {e}"))?
            .with_intra_threads(threads.max(1))
            .map_err(|e| format!("with_intra_threads failed: {e}"))?
            .with_inter_threads(1)
            .map_err(|e| format!("with_inter_threads failed: {e}"))?
            .commit_from_file(model_path)
            .map_err(|e| format!("failed loading {}: {e}", model_path.display()))?;

        let (
            window_size,
            sample_rate,
            window_shift,
            receptive_field_size,
            receptive_field_shift,
            num_speakers,
            powerset_max_classes,
            num_classes,
        ) = {
            let meta = session.metadata().map_err(|e| e.to_string())?;
            let parse_meta = |key: &str, default: usize| -> usize {
                meta.custom(key)
                    .and_then(|s| s.trim().parse::<usize>().ok())
                    .filter(|&v| v > 0)
                    .unwrap_or(default)
            };

            let window_size = parse_meta("window_size", 160_000);
            let sample_rate = parse_meta("sample_rate", 16_000);
            let window_shift = (window_size / 10).max(1);
            let receptive_field_size = parse_meta("receptive_field_size", 721);
            let receptive_field_shift = parse_meta("receptive_field_shift", 270);
            let num_speakers = parse_meta("num_speakers", 3);
            let powerset_max_classes = parse_meta("powerset_max_classes", 2);
            let num_classes = parse_meta("num_classes", 7);
            (
                window_size,
                sample_rate,
                window_shift,
                receptive_field_size,
                receptive_field_shift,
                num_speakers,
                powerset_max_classes,
                num_classes,
            )
        };

        let powerset_speech_mask =
            build_powerset_speech_mask(num_classes, num_speakers, powerset_max_classes);

        Ok(Self {
            session: Mutex::new(session),
            window_size,
            sample_rate,
            window_shift,
            receptive_field_size,
            receptive_field_shift,
            num_classes,
            powerset_speech_mask,
        })
    }

    pub fn detect(
        &self,
        samples: &[f32],
        duration_ms: i64,
        min_speech_ms: i64,
        min_silence_ms: i64,
    ) -> Result<Vec<VadSegment>, String> {
        if samples.is_empty() || duration_ms <= 0 {
            return Ok(Vec::new());
        }

        let num_full = if samples.len() >= self.window_size {
            (samples.len() - self.window_size) / self.window_shift + 1
        } else {
            0
        };
        let has_last_chunk =
            samples.len() < self.window_size || (samples.len() - self.window_size) % self.window_shift > 0;
        let total_chunks = num_full + if has_last_chunk { 1 } else { 0 };
        if total_chunks == 0 {
            return Ok(Vec::new());
        }

        let mut chunk_speech: Vec<Vec<f32>> = Vec::with_capacity(total_chunks);
        let mut num_frames_per_chunk = 0usize;

        {
            let mut session = self
                .session
                .lock()
                .map_err(|_| "Pyannote session lock poisoned".to_string())?;

            let batch_size = 16usize;
            for batch_start in (0..num_full).step_by(batch_size) {
                let batch_end = (batch_start + batch_size).min(num_full);
                let cur_batch = batch_end - batch_start;
                let mut flat = Vec::with_capacity(cur_batch * self.window_size);
                for idx in batch_start..batch_end {
                    let offset = idx * self.window_shift;
                    flat.extend_from_slice(&samples[offset..offset + self.window_size]);
                }
                let input = Tensor::from_array(([cur_batch, 1usize, self.window_size], flat))
                    .map_err(|e| format!("failed creating VAD input tensor: {e}"))?;
                let outputs = session
                    .run(ort::inputs![input])
                    .map_err(|e| format!("Pyannote VAD inference failed: {e}"))?;
                let (shape, logits) = outputs[0]
                    .try_extract_tensor::<f32>()
                    .map_err(|e| format!("failed extracting VAD output tensor: {e}"))?;
                append_batch_speech_probs(
                    shape.as_ref(),
                    logits,
                    self.num_classes,
                    &self.powerset_speech_mask,
                    &mut num_frames_per_chunk,
                    &mut chunk_speech,
                )?;
            }

            if has_last_chunk {
                let offset = num_full * self.window_shift;
                let tail = &samples[offset..];
                let mut padded = vec![0.0f32; self.window_size];
                let copy_len = tail.len().min(self.window_size);
                padded[..copy_len].copy_from_slice(&tail[..copy_len]);
                let input = Tensor::from_array(([1usize, 1usize, self.window_size], padded))
                    .map_err(|e| format!("failed creating VAD tail tensor: {e}"))?;
                let outputs = session
                    .run(ort::inputs![input])
                    .map_err(|e| format!("Pyannote VAD tail inference failed: {e}"))?;
                let (shape, logits) = outputs[0]
                    .try_extract_tensor::<f32>()
                    .map_err(|e| format!("failed extracting VAD tail tensor: {e}"))?;
                append_batch_speech_probs(
                    shape.as_ref(),
                    logits,
                    self.num_classes,
                    &self.powerset_speech_mask,
                    &mut num_frames_per_chunk,
                    &mut chunk_speech,
                )?;
            }
        }

        if chunk_speech.is_empty() || num_frames_per_chunk == 0 {
            return Ok(Vec::new());
        }

        let raw_segments = aggregate_frames_to_segments(
            &chunk_speech,
            num_frames_per_chunk,
            samples.len(),
            has_last_chunk,
            self.window_size,
            self.window_shift,
            self.receptive_field_size,
            self.receptive_field_shift,
            self.sample_rate,
            duration_ms,
        );

        Ok(postprocess_segments(
            raw_segments,
            min_silence_ms.max(0),
            min_speech_ms.max(0),
        ))
    }
}

pub fn build_powerset_speech_mask(
    num_classes: usize,
    num_speakers: usize,
    powerset_max_classes: usize,
) -> Vec<bool> {
    let mut mask = vec![false; num_classes];
    let mut k = 1usize;
    for order in 1..=powerset_max_classes {
        if order == 1 {
            for _ in 0..num_speakers {
                if k < num_classes {
                    mask[k] = true;
                }
                k += 1;
            }
        } else if order == 2 {
            for j in 0..num_speakers {
                for _m in (j + 1)..num_speakers {
                    if k < num_classes {
                        mask[k] = true;
                    }
                    k += 1;
                }
            }
        } else {
            while k < num_classes {
                mask[k] = true;
                k += 1;
            }
        }
    }
    mask
}

fn append_batch_speech_probs(
    shape: &[i64],
    logits: &[f32],
    expected_classes: usize,
    speech_mask: &[bool],
    num_frames_out: &mut usize,
    chunk_speech: &mut Vec<Vec<f32>>,
) -> Result<(), String> {
    if shape.len() != 3 {
        return Err(format!("unexpected Pyannote output rank {}", shape.len()));
    }
    let batch = shape[0].max(0) as usize;
    let frames = shape[1].max(0) as usize;
    let classes = shape[2].max(0) as usize;
    if classes != expected_classes || classes == 0 || frames == 0 {
        return Err(format!(
            "unexpected Pyannote output shape {:?} (expected *,*,{expected_classes})",
            shape
        ));
    }
    *num_frames_out = frames;

    for b in 0..batch {
        let mut frame_vals = Vec::with_capacity(frames);
        for f in 0..frames {
            let base = (b * frames + f) * classes;
            let mut best_c = 0usize;
            let mut best_val = logits[base];
            for (c, &v) in logits[base..base + classes].iter().enumerate().skip(1) {
                if v > best_val {
                    best_val = v;
                    best_c = c;
                }
            }
            let active = speech_mask.get(best_c).copied().unwrap_or(best_c > 0);
            frame_vals.push(if active { 1.0 } else { 0.0 });
        }
        chunk_speech.push(frame_vals);
    }
    Ok(())
}

fn hamming_window(len: usize) -> Vec<f64> {
    if len <= 1 {
        return vec![1.0; len];
    }
    let denom = (len - 1) as f64;
    (0..len)
        .map(|n| 0.54 - 0.46 * (2.0 * std::f64::consts::PI * (n as f64) / denom).cos())
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn aggregate_frames_to_segments(
    chunk_speech: &[Vec<f32>],
    frames_per_chunk: usize,
    total_samples: usize,
    has_last_chunk: bool,
    window_size: usize,
    window_shift: usize,
    receptive_field_size: usize,
    receptive_field_shift: usize,
    sample_rate: usize,
    duration_ms: i64,
) -> Vec<VadSegment> {
    let total_frame_capacity =
        ((window_size + (chunk_speech.len() - 1) * window_shift) / receptive_field_shift) + frames_per_chunk + 2;
    let mut sum = vec![0.0f64; total_frame_capacity];
    let mut weight_sum = vec![0.0f64; total_frame_capacity];
    let weights = hamming_window(frames_per_chunk);

    for (chunk_idx, frames) in chunk_speech.iter().enumerate() {
        let start_frame = ((chunk_idx * window_shift) as f64 / (receptive_field_shift as f64) + 0.5) as usize;
        for (f_idx, (&val, &w)) in frames.iter().zip(weights.iter()).enumerate() {
            let target = start_frame + f_idx;
            if target < total_frame_capacity {
                sum[target] += (val as f64) * w;
                weight_sum[target] += w;
            }
        }
    }

    let valid_frames = if has_last_chunk {
        (total_samples / receptive_field_shift).clamp(1, total_frame_capacity)
    } else {
        total_frame_capacity
    };

    let mut probs = Vec::with_capacity(valid_frames);
    for i in 0..valid_frames {
        let w = weight_sum[i].max(1e-12);
        probs.push(sum[i] / w);
    }

    let onset = 0.5f64;
    let offset = 0.5f64;
    let scale_ms = (receptive_field_shift as f64 / sample_rate as f64) * 1000.0;
    let offset_ms = (receptive_field_size as f64 / sample_rate as f64) * 500.0;

    let mut segments = Vec::new();
    let mut is_active = probs[0] > onset;
    let mut start_idx = 0usize;

    for (i, &p) in probs.iter().enumerate() {
        if is_active {
            if p < offset {
                let s = ((start_idx as f64 * scale_ms + offset_ms).round() as i64).clamp(0, duration_ms);
                let e = ((i as f64 * scale_ms + offset_ms).round() as i64).clamp(0, duration_ms);
                if e > s {
                    segments.push(VadSegment {
                        start_ms: s,
                        end_ms: e,
                    });
                }
                is_active = false;
            }
        } else if p > onset {
            start_idx = i;
            is_active = true;
        }
    }

    if is_active {
        let last = probs.len().saturating_sub(1);
        let s = ((start_idx as f64 * scale_ms + offset_ms).round() as i64).clamp(0, duration_ms);
        let e = ((last as f64 * scale_ms + offset_ms).round() as i64).clamp(0, duration_ms);
        if e > s {
            segments.push(VadSegment {
                start_ms: s,
                end_ms: e,
            });
        }
    }

    segments
}

pub fn postprocess_segments(
    segments: Vec<VadSegment>,
    min_silence_ms: i64,
    min_speech_ms: i64,
) -> Vec<VadSegment> {
    if segments.is_empty() {
        return segments;
    }

    let mut merged: Vec<VadSegment> = Vec::with_capacity(segments.len());
    for seg in segments {
        if let Some(prev) = merged.last_mut() {
            if seg.start_ms - prev.end_ms <= min_silence_ms {
                prev.end_ms = prev.end_ms.max(seg.end_ms);
                continue;
            }
        }
        merged.push(seg);
    }

    merged
        .into_iter()
        .filter(|s| s.end_ms - s.start_ms >= min_speech_ms)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn powerset_mask_marks_single_and_overlap_speaker_classes() {
        let mask = build_powerset_speech_mask(7, 3, 2);
        assert_eq!(mask, vec![false, true, true, true, true, true, true]);
    }

    #[test]
    fn postprocess_merges_short_silences_and_filters_short_bursts() {
        let raw = vec![
            VadSegment { start_ms: 100, end_ms: 200 },  // short burst 100ms
            VadSegment { start_ms: 900, end_ms: 1400 },
            VadSegment { start_ms: 1650, end_ms: 2200 }, // 250ms gap <= 500ms -> merged
        ];
        let out = postprocess_segments(raw, 500, 250);
        assert_eq!(
            out,
            vec![VadSegment {
                start_ms: 900,
                end_ms: 2200
            }]
        );
    }

    #[test]
    fn aggregates_synthetic_chunk_activity_into_timed_segments() {
        let mut frames = vec![0.0f32; 589];
        for f in &mut frames[100..250] {
            *f = 1.0;
        }
        let segs = aggregate_frames_to_segments(
            &[frames],
            589,
            160_000,
            false,
            160_000,
            16_000,
            721,
            270,
            16_000,
            10_000,
        );
        assert_eq!(segs.len(), 1);
        assert!(segs[0].start_ms >= 1500 && segs[0].start_ms <= 2000);
        assert!(segs[0].end_ms >= 4000 && segs[0].end_ms <= 4500);
    }
}

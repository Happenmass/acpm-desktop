use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::process::Command;

pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// Loads an audio file as 16 kHz mono f32 samples in `[-1.0, 1.0]` plus total duration in ms.
/// Reads PCM16 / PCM32F WAV directly in pure Rust and falls back to `ffmpeg` for compressed formats.
pub fn load_audio_16k_mono(path: &Path) -> Result<(Vec<f32>, i64), String> {
    if !path.is_file() {
        return Err(format!("audio file does not exist: {}", path.display()));
    }

    if let Ok((samples, sample_rate)) = try_read_wav_mono(path) {
        let resampled = if sample_rate == TARGET_SAMPLE_RATE {
            samples
        } else {
            resample_linear(&samples, sample_rate, TARGET_SAMPLE_RATE)
        };
        let duration_ms = ((resampled.len() as f64 / TARGET_SAMPLE_RATE as f64) * 1000.0).round() as i64;
        return Ok((resampled, duration_ms));
    }

    decode_via_ffmpeg(path)
}

fn try_read_wav_mono(path: &Path) -> Result<(Vec<f32>, u32), String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    decode_wav_bytes_mono(&bytes)
}

pub fn decode_wav_bytes_mono(bytes: &[u8]) -> Result<(Vec<f32>, u32), String> {
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".to_string());
    }

    let mut pos = 12usize;
    let mut audio_format: Option<u16> = None;
    let mut channels: Option<u16> = None;
    let mut sample_rate: Option<u32> = None;
    let mut bits_per_sample: Option<u16> = None;
    let mut data_slice: Option<&[u8]> = None;

    while pos + 8 <= bytes.len() {
        let chunk_id = &bytes[pos..pos + 4];
        let chunk_size = u32::from_le_bytes([
            bytes[pos + 4],
            bytes[pos + 5],
            bytes[pos + 6],
            bytes[pos + 7],
        ]) as usize;
        pos += 8;
        let padded_end = pos.saturating_add(chunk_size).min(bytes.len());
        let chunk = &bytes[pos..padded_end];

        if chunk_id == b"fmt " && chunk.len() >= 16 {
            audio_format = Some(u16::from_le_bytes([chunk[0], chunk[1]]));
            channels = Some(u16::from_le_bytes([chunk[2], chunk[3]]));
            sample_rate = Some(u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]));
            bits_per_sample = Some(u16::from_le_bytes([chunk[14], chunk[15]]));
        } else if chunk_id == b"data" {
            data_slice = Some(chunk);
        }

        pos = pos
            .saturating_add(chunk_size)
            .saturating_add(chunk_size % 2);
    }

    let fmt = audio_format.ok_or_else(|| "missing WAV fmt chunk".to_string())?;
    let ch = channels.filter(|&c| c > 0).ok_or_else(|| "invalid channels".to_string())? as usize;
    let sr = sample_rate.filter(|&r| r > 0).ok_or_else(|| "invalid sample rate".to_string())?;
    let bps = bits_per_sample.ok_or_else(|| "missing bits per sample".to_string())?;
    let data = data_slice.ok_or_else(|| "missing WAV data chunk".to_string())?;

    let frame_samples = match (fmt, bps) {
        (1, 16) => data
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0)
            .collect::<Vec<f32>>(),
        (3, 32) => data
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect::<Vec<f32>>(),
        _ => return Err(format!("unsupported WAV format={fmt} bits={bps}")),
    };

    if ch == 1 {
        return Ok((frame_samples, sr));
    }

    let mono = frame_samples
        .chunks(ch)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect();
    Ok((mono, sr))
}

pub fn resample_linear(input: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
    if input.is_empty() || src_rate == 0 || dst_rate == 0 || src_rate == dst_rate {
        return input.to_vec();
    }
    let ratio = src_rate as f64 / dst_rate as f64;
    let out_len = ((input.len() as f64) / ratio).round().max(1.0) as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src_pos = (i as f64) * ratio;
        let idx = src_pos.floor() as usize;
        let frac = (src_pos - idx as f64) as f32;
        if idx + 1 < input.len() {
            out.push(input[idx] * (1.0 - frac) + input[idx + 1] * frac);
        } else {
            out.push(input[input.len() - 1]);
        }
    }
    out
}

fn decode_via_ffmpeg(path: &Path) -> Result<(Vec<f32>, i64), String> {
    let output = Command::new("ffmpeg")
        .args(["-v", "error", "-i"])
        .arg(path)
        .args(["-ac", "1", "-ar", "16000", "-f", "f32le", "-"])
        .output()
        .map_err(|e| format!("failed executing ffmpeg fallback: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("ffmpeg failed decoding '{}': {stderr}", path.display()));
    }

    let samples: Vec<f32> = output
        .stdout
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    let duration_ms = ((samples.len() as f64 / TARGET_SAMPLE_RATE as f64) * 1000.0).round() as i64;
    Ok((samples, duration_ms))
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn encode_pcm16_wav(samples: &[f32], sample_rate: u32) -> Vec<u8> {
        let data_size = (samples.len() * 2) as u32;
        let chunk_size = 36 + data_size;
        let byte_rate = sample_rate * 2;
        let mut out = Vec::with_capacity(44 + data_size as usize);
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&chunk_size.to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&byte_rate.to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_size.to_le_bytes());
        for &s in samples {
            let v = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
            out.extend_from_slice(&v.to_le_bytes());
        }
        out
    }

    #[test]
    fn loads_and_resamples_24khz_wav_to_16khz() {
        let path = std::env::temp_dir().join(format!("acpm-audio-test-{}.wav", Uuid::new_v4()));
        // 1.5 seconds of 440Hz sine wave at 24 kHz
        let src_sr = 24_000u32;
        let total_src = 36_000usize;
        let samples: Vec<f32> = (0..total_src)
            .map(|i| (2.0 * std::f32::consts::PI * 440.0 * (i as f32 / src_sr as f32)).sin() * 0.5)
            .collect();
        std::fs::write(&path, encode_pcm16_wav(&samples, src_sr)).unwrap();

        let (out, duration_ms) = load_audio_16k_mono(&path).unwrap();
        assert_eq!(out.len(), 24_000);
        assert_eq!(duration_ms, 1500);

        let _ = std::fs::remove_file(&path);
    }
}

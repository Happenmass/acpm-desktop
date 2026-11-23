use std::path::{Path, PathBuf};

fn candidate_lib_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(env_dir) = std::env::var("ACPM_SHERPA_LIB_DIR") {
        let trimmed = env_dir.trim();
        if !trimmed.is_empty() {
            dirs.push(PathBuf::from(trimmed));
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            dirs.push(exe_dir.to_path_buf());
            dirs.push(exe_dir.join("lib"));
            dirs.push(exe_dir.join("../Frameworks"));
            for ancestor in exe_dir.ancestors().take(6) {
                dirs.push(ancestor.join(".cache/sherpa-onnx/v2.0.3/lib"));
            }
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        for ancestor in cwd.ancestors().take(5) {
            dirs.push(ancestor.join(".cache/sherpa-onnx/v2.0.3/lib"));
        }
    }
    #[cfg(target_os = "macos")]
    {
        dirs.push(PathBuf::from("/opt/homebrew/lib"));
        dirs.push(PathBuf::from("/usr/local/lib"));
    }
    dirs
}

fn find_in_dirs(dirs: &[PathBuf], names: &[&str], prefix: Option<&str>) -> Option<PathBuf> {
    for dir in dirs {
        if !dir.is_dir() {
            continue;
        }
        for name in names {
            let p = dir.join(name);
            if p.is_file() {
                return Some(p);
            }
        }
        if let Some(pref) = prefix {
            if let Ok(entries) = std::fs::read_dir(dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if let Some(fname) = path.file_name().and_then(|s| s.to_str()) {
                        if fname.starts_with(pref) && fname.ends_with(".dylib") && path.is_file() {
                            return Some(path);
                        }
                    }
                }
            }
        }
    }
    None
}

pub fn resolve_onnxruntime_dylib() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("ORT_DYLIB_PATH") {
        let p = PathBuf::from(explicit);
        if p.is_file() {
            return Some(p);
        }
    }
    let dirs = candidate_lib_dirs();
    find_in_dirs(
        &dirs,
        &[
            "libonnxruntime.dylib",
            "libonnxruntime.1.28.2.dylib",
            "libonnxruntime.so",
            "onnxruntime.dll",
        ],
        Some("libonnxruntime."),
    )
}

pub fn resolve_model_file(model_dir: &Path, candidates: &[&str]) -> Option<PathBuf> {
    if model_dir.is_file() {
        return Some(model_dir.to_path_buf());
    }
    for name in candidates {
        let p = model_dir.join(name);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

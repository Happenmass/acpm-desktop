import Darwin
import Foundation

/// Reads real macOS physical memory footprint (`ri_phys_footprint`) via `proc_pid_rusage`
/// so `mmap`-backed safetensors weights do not distort memory accounting.
public enum ProcessMemory {
    public static func physFootprintBytes(pid: pid_t = getpid()) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { _ in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutablePointer(OpaquePointer(ptr)))
            }
        }
        guard result == 0 else {
            return 0
        }
        return info.ri_phys_footprint
    }

    public static func physFootprintMB(pid: pid_t = getpid()) -> UInt64 {
        physFootprintBytes(pid: pid) / (1024 * 1024)
    }

    public static func currentUnifiedMB() -> UInt64 {
        physFootprintMB(pid: getpid())
    }
}

/// Resolves the Metal shader library (`default.metallib` / `mlx.metallib`) when running
/// SwiftPM-built binaries without Xcode's `MetalToolchain` installed.
public enum MetallibLocator {
    public static func resolveMetallibURL() -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        for key in ["ACPM_METALLIB_PATH", "MLX_METALLIB_PATH"] {
            if let value = env[key], !value.isEmpty, fm.fileExists(atPath: value) {
                return URL(fileURLWithPath: value)
            }
        }

        if let execURL = Bundle.main.executableURL {
            let execDir = execURL.deletingLastPathComponent()
            let candidates = [
                execDir.appendingPathComponent("default.metallib"),
                execDir.appendingPathComponent("mlx.metallib"),
                execDir.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
                execDir.deletingLastPathComponent().appendingPathComponent("Resources/default.metallib"),
                execDir.deletingLastPathComponent().appendingPathComponent("Resources/mlx.metallib"),
            ]
            for candidate in candidates where fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        var cursor = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let cached = cursor.appendingPathComponent(".cache/mlx-metallib/0.33.0/default.metallib")
            if fm.fileExists(atPath: cached.path) {
                return cached
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }

        if let execURL = Bundle.main.executableURL {
            var execCursor = execURL.deletingLastPathComponent()
            for _ in 0..<8 {
                let cached = execCursor.appendingPathComponent(".cache/mlx-metallib/0.33.0/default.metallib")
                if fm.fileExists(atPath: cached.path) {
                    return cached
                }
                let parent = execCursor.deletingLastPathComponent()
                if parent.path == execCursor.path { break }
                execCursor = parent
            }
        }

        return nil
    }
}

import Darwin
import Foundation

public struct RuntimeDiscovery: Codable, Sendable, Equatable {
    public let version: Int
    public let pid: Int32
    public let startedAt: String
    public let httpBaseUrl: String
    public let nativeIpcPath: String
    public let token: String
    public let platform: String
    public let capabilities: [String]
    public let mdnsHostname: String?
    public let mdnsBaseUrl: String?

    enum CodingKeys: String, CodingKey {
        case version
        case pid
        case startedAt = "started_at"
        case httpBaseUrl = "http_base_url"
        case nativeIpcPath = "native_ipc_path"
        case token
        case platform
        case capabilities
        case mdnsHostname = "mdns_hostname"
        case mdnsBaseUrl = "mdns_base_url"
    }

    public var baseURL: URL? {
        URL(string: httpBaseUrl)
    }

    public var mdnsURL: URL? {
        mdnsBaseUrl.flatMap(URL.init(string:))
    }

    public static func defaultDataDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("acpm-desktop", isDirectory: true)
    }

    public static func discover(dataDirectory: URL? = nil, verifyAlive: Bool = true) throws -> RuntimeDiscovery {
        let dir = dataDirectory ?? defaultDataDirectory()
        let fileURL = dir.appendingPathComponent("runtime.json", isDirectory: false)
        let data = try Data(contentsOf: fileURL)
        let info = try JSONDecoder().decode(RuntimeDiscovery.self, from: data)
        if verifyAlive && !isProcessAlive(pid: info.pid) {
            throw AcpmDiscoveryError.staleRuntimeFile(pid: info.pid)
        }
        return info
    }

    public static func isProcessAlive(pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

public enum AcpmDiscoveryError: Error, Sendable, Equatable {
    case staleRuntimeFile(pid: Int32)
}

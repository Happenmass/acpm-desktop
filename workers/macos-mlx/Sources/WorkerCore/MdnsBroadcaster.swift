import Darwin
import Foundation

/// Registers a fixed `.local` mDNS hostname and `_acpm._tcp.local.` service record
/// via macOS `/usr/bin/dns-sd -P`, tracking active LAN IPv4 changes automatically.
public final class MdnsBroadcaster: @unchecked Sendable {
    private let serviceName: String
    public let hostname: String
    public let port: UInt16
    private let capabilities: [String]

    private let lock = NSLock()
    private var process: Process?
    private var currentIP: String?
    private var monitorTask: Task<Void, Never>?

    public var activeIP: String? {
        lock.withLock { currentIP }
    }

    public init(
        serviceName: String = "acpm-desktop",
        hostname: String = "acpm.local",
        port: UInt16,
        capabilities: [String] = ["llm", "asr", "tts"]
    ) {
        self.serviceName = serviceName
        self.hostname = Self.normalizeHostname(hostname)
        self.port = port
        self.capabilities = capabilities
    }

    deinit {
        stop()
    }

    public static func normalizeHostname(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        if trimmed.isEmpty {
            return "acpm.local"
        }
        return trimmed.contains(".") ? trimmed : "\(trimmed).local"
    }

    public static func detectLanIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return nil
        }
        defer { freeifaddrs(ifaddrPtr) }

        var preferred: [(priority: Int, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback, let addr = interface.ifa_addr else {
                continue
            }
            guard addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") {
                continue
            }

            var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostnameBuffer,
                socklen_t(hostnameBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            let ipBytes = hostnameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let ip = String(decoding: ipBytes, as: UTF8.self)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") || ip == "0.0.0.0" {
                continue
            }

            let priority: Int
            if name == "en0" {
                priority = 0
            } else if name == "en1" {
                priority = 1
            } else if name.hasPrefix("en") {
                priority = 2
            } else {
                priority = 3
            }
            preferred.append((priority, ip))
        }

        return preferred.sorted { $0.priority < $1.priority }.first?.ip
    }

    public func start() {
        refreshRegistration()
        lock.withLock {
            guard monitorTask == nil else { return }
            monitorTask = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    if Task.isCancelled { break }
                    self?.refreshRegistration()
                }
            }
        }
    }

    public func stop() {
        let (task, proc) = lock.withLock { () -> (Task<Void, Never>?, Process?) in
            let t = monitorTask
            monitorTask = nil
            let p = process
            process = nil
            currentIP = nil
            return (t, p)
        }
        task?.cancel()
        if let proc, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
    }

    private func refreshRegistration() {
        let nextIP = Self.detectLanIPv4()
        let needsRespawn = lock.withLock { () -> Bool in
            let dead = process.map { !$0.isRunning } ?? true
            return nextIP != currentIP || (nextIP != nil && dead)
        }
        guard needsRespawn else { return }

        let oldProc = lock.withLock { () -> Process? in
            let old = process
            process = nil
            currentIP = nextIP
            return old
        }
        if let oldProc, oldProc.isRunning {
            oldProc.terminate()
            oldProc.waitUntilExit()
        }

        guard let lanIP = nextIP else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        proc.arguments = [
            "-P",
            serviceName,
            "_acpm._tcp",
            "local.",
            "\(port)",
            "\(hostname).",
            lanIP,
            "version=1",
            "host=\(hostname)",
            "port=\(port)",
            "capabilities=\(capabilities.joined(separator: ","))",
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            lock.withLock {
                process = proc
                currentIP = lanIP
            }
        } catch {
            lock.withLock {
                process = nil
            }
        }
    }
}

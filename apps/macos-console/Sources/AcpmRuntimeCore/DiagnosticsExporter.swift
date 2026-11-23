import AcpmClient
import Foundation

public struct RedactedConfigSummary: Codable, Sendable, Equatable {
    public let budgetTier: String
    public let budgetOverrideMb: UInt64?
    public let effectiveBudget: ResourceVectorDTO
    public let dataDir: String
    public let modelsDir: String
    public let voicesDir: String
    public let configPath: String
    public let configuredModelOverrides: [String: ModelConfigOverrideSummary]

    public init(from cfg: SystemConfigResponse) {
        self.budgetTier = cfg.budgetTier
        self.budgetOverrideMb = cfg.budgetOverrideMb
        self.effectiveBudget = cfg.effectiveBudget
        self.dataDir = cfg.dataDir
        self.modelsDir = cfg.modelsDir
        self.voicesDir = cfg.voicesDir
        self.configPath = cfg.configPath
        self.configuredModelOverrides = cfg.modelOverrides
    }
}

public struct RedactedDiagnosticsBundle: Codable, Sendable, Equatable {
    public let exportedAt: String
    public let appVersion: String
    public let hostRamGB: Int
    public let hardwareTier: String
    public let connected: Bool
    public let mdnsHostname: String?
    public let mdnsBaseUrl: String?
    public let httpBaseUrl: String?
    public let systemStatus: SystemStatusResponse?
    public let models: [ModelStatusInfo]
    public let configSummary: RedactedConfigSummary?
    public let recentFailures: [DiagnosticFailure]

    public init(
        exportedAt: String,
        appVersion: String,
        hostRamGB: Int,
        hardwareTier: String,
        connected: Bool,
        mdnsHostname: String?,
        mdnsBaseUrl: String?,
        httpBaseUrl: String?,
        systemStatus: SystemStatusResponse?,
        models: [ModelStatusInfo],
        configSummary: RedactedConfigSummary?,
        recentFailures: [DiagnosticFailure]
    ) {
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.hostRamGB = hostRamGB
        self.hardwareTier = hardwareTier
        self.connected = connected
        self.mdnsHostname = mdnsHostname
        self.mdnsBaseUrl = mdnsBaseUrl
        self.httpBaseUrl = httpBaseUrl
        self.systemStatus = systemStatus
        self.models = models
        self.configSummary = configSummary
        self.recentFailures = recentFailures
    }
}

public enum DiagnosticsExporter {
    public static func buildBundle(
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
        hardware: HardwareRecommendation,
        connected: Bool,
        discovery: RuntimeDiscovery?,
        status: SystemStatusResponse?,
        models: [ModelStatusInfo],
        config: SystemConfigResponse?,
        recentFailures: [DiagnosticFailure],
        exportedAt: Date = Date()
    ) -> RedactedDiagnosticsBundle {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return RedactedDiagnosticsBundle(
            exportedAt: fmt.string(from: exportedAt),
            appVersion: appVersion,
            hostRamGB: hardware.ramGB,
            hardwareTier: hardware.tier.rawValue,
            connected: connected,
            mdnsHostname: config?.mdnsHostname ?? discovery?.mdnsHostname,
            mdnsBaseUrl: config?.mdnsBaseUrl ?? discovery?.mdnsBaseUrl,
            httpBaseUrl: config?.httpBaseUrl ?? discovery?.httpBaseUrl,
            systemStatus: status,
            models: models,
            configSummary: config.map(RedactedConfigSummary.init(from:)),
            recentFailures: recentFailures
        )
    }

    public static func buildJSONData(
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
        hardware: HardwareRecommendation,
        connected: Bool,
        discovery: RuntimeDiscovery?,
        status: SystemStatusResponse?,
        models: [ModelStatusInfo],
        config: SystemConfigResponse?,
        recentFailures: [DiagnosticFailure],
        exportedAt: Date = Date()
    ) throws -> Data {
        let bundle = buildBundle(
            appVersion: appVersion,
            hardware: hardware,
            connected: connected,
            discovery: discovery,
            status: status,
            models: models,
            config: config,
            recentFailures: recentFailures,
            exportedAt: exportedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }
}

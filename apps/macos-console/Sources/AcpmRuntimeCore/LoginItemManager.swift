import Foundation
import Observation
import ServiceManagement

@Observable
@MainActor
public final class LoginItemManager {
    public private(set) var isEnabled: Bool = false
    public private(set) var requiresApproval: Bool = false
    public private(set) var statusDescription: String = "未启用"
    public private(set) var isBundledApp: Bool = false
    public private(set) var lastError: String?

    public init() {
        refresh()
    }

    public func refresh() {
        isBundledApp = Bundle.main.bundleURL.pathExtension == "app"
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
            statusDescription = "已开启登录自启"
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
            statusDescription = "需要在「系统设置 -> 通用 -> 登录项」中允许"
        case .notRegistered:
            isEnabled = false
            requiresApproval = false
            statusDescription = "未注册开机自启"
        case .notFound:
            isEnabled = false
            requiresApproval = false
            statusDescription = isBundledApp ? "未找到主应用包" : "仅在 AcpmRuntime.app 打包运行后支持注册"
        @unknown default:
            isEnabled = false
            requiresApproval = false
            statusDescription = "未知状态"
        }
    }

    public func setEnabled(_ enabled: Bool) {
        lastError = nil
        isBundledApp = Bundle.main.bundleURL.pathExtension == "app"
        guard isBundledApp else {
            lastError = "当前以命令行二进制运行，请先打包 dist/AcpmRuntime.app 后再启用 SMAppService 开机自启。"
            refresh()
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "更新登录项失败：\(error.localizedDescription)"
        }
        refresh()
    }
}

import AcpmClient
import AcpmRuntimeCore
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate, NSPopoverDelegate {
    let viewModel: RuntimeViewModel

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var consoleWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var workspaceAppActivateObserver: NSObjectProtocol?
    private var workspaceSpaceChangeObserver: NSObjectProtocol?

    init(viewModel: RuntimeViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        configureStatusButton()
        configurePopover()
        updateStatusItemAppearance()
        observeStatusChanges()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        let rootView = MenuBarPopoverView(
            viewModel: viewModel,
            onOpenConsole: { [weak self] tab in
                self?.showConsoleWindow(tab: tab)
            },
            onOpenSettings: { [weak self] in
                self?.showSettingsWindow()
            },
            onOpenOnboarding: { [weak self] in
                self?.showConsoleWindow(tab: .overview, openOnboarding: true)
            },
            onClose: { [weak self] in
                self?.closePopover()
            }
        )
        popover.contentViewController = NSHostingController(rootView: rootView)
        popover.appearance = viewModel.appearance.nsAppearance
    }

    private func observeStatusChanges() {
        withObservationTracking {
            _ = viewModel.statusBarVisualState
            _ = viewModel.connected
            _ = viewModel.isStartingDaemon
            _ = viewModel.status?.activeRequests
            _ = viewModel.appearance
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusItemAppearance()
                self?.observeStatusChanges()
            }
        }
    }

    private func updateStatusItemAppearance() {
        NSApp.appearance = viewModel.appearance.nsAppearance
        popover.appearance = viewModel.appearance.nsAppearance

        guard let button = statusItem.button else { return }
        let symbolName: String
        let alpha: CGFloat
        let accessibilityText: String

        switch viewModel.statusBarVisualState {
        case .offline:
            symbolName = "waveform.slash"
            alpha = 0.55
            accessibilityText = "\(AcpmTheme.productName) · 离线"
        case .idle:
            symbolName = "waveform"
            alpha = 1.0
            accessibilityText = "\(AcpmTheme.productName) · 运行中"
        case .busy:
            symbolName = "waveform.circle.fill"
            alpha = 1.0
            accessibilityText = "\(AcpmTheme.productName) · 推理中"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityText)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.alphaValue = alpha
        button.toolTip = accessibilityText
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        let isRight = ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true

        if isRight {
            closePopover()
            statusItem.menu = makeContextMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            if popover.isShown {
                closePopover()
            } else {
                showPopover(from: sender)
            }
        }
    }

    private func showPopover(from sender: NSStatusBarButton) {
        viewModel.startMonitoring()
        Task { await viewModel.refresh() }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
        installPopoverDismissMonitors()
    }

    func closePopover() {
        removePopoverDismissMonitors()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverDismissMonitors()
    }

    // Use explicit global/local monitors rather than `.transient` alone because
    // LSUIElement (.accessory) popovers on macOS 15 often miss outside clicks
    // onto other apps/desktop or double-toggle on leftMouseUp.
    private func installPopoverDismissMonitors() {
        removePopoverDismissMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseDown(at: clickLocation)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            let isKeyDown = event.type == .keyDown
            let isEscapeKey = isKeyDown && event.keyCode == 53
            let windowNumber = event.windowNumber
            let consume = MainActor.assumeIsolated {
                self?.handleLocalEvent(
                    isKeyDown: isKeyDown,
                    isEscapeKey: isEscapeKey,
                    windowNumber: windowNumber
                ) ?? false
            }
            return consume ? nil : event
        }

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }

        workspaceAppActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            let ownPID = ProcessInfo.processInfo.processIdentifier
            if activatedPID != ownPID {
                Task { @MainActor [weak self] in
                    self?.closePopover()
                }
            }
        }

        workspaceSpaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func removePopoverDismissMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        if let workspaceAppActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceAppActivateObserver)
            self.workspaceAppActivateObserver = nil
        }
        if let workspaceSpaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceSpaceChangeObserver)
            self.workspaceSpaceChangeObserver = nil
        }
    }

    private func handleGlobalMouseDown(at screenLocation: NSPoint) {
        guard popover.isShown else { return }
        if popover.contentViewController?.view.window?.frame.contains(screenLocation) == true {
            return
        }
        if statusItem.button?.window?.frame.contains(screenLocation) == true {
            return
        }
        closePopover()
    }

    private func handleLocalEvent(
        isKeyDown: Bool,
        isEscapeKey: Bool,
        windowNumber: Int
    ) -> Bool {
        guard popover.isShown else { return false }
        if isKeyDown {
            if isEscapeKey {
                closePopover()
                return true
            }
            return false
        }

        let popoverWindow = popover.contentViewController?.view.window
        let statusWindow = statusItem.button?.window
        if let targetWindow = NSApp.window(withWindowNumber: windowNumber),
           targetWindow === popoverWindow
            || targetWindow.parent === popoverWindow
            || targetWindow === statusWindow {
            return false
        }

        closePopover()
        return false
    }

    // MARK: - Right-Click Context Menu

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false

        // 1. Live Status / Start Service
        if viewModel.connected, let status = viewModel.status {
            let usedGB = Double(status.used.totalMB) / 1024.0
            let budgetGB = Double(status.budget.totalMB) / 1024.0
            let pressure = AcpmTheme.pressureLabel(status.memoryPressure)
            let stateText = viewModel.statusBarVisualState == .busy ? "推理中" : "运行中"
            let title = String(format: "● %@ · %.1f / %.0f GB · 压力%@", stateText, usedGB, budgetGB, pressure)
            let statusHeader = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            statusHeader.isEnabled = false
            menu.addItem(statusHeader)
        } else {
            let startTitle = viewModel.isStartingDaemon ? "正在启动 AI 服务…" : "启动 AI 服务"
            let startItem = NSMenuItem(title: startTitle, action: #selector(startServiceFromMenu), keyEquivalent: "")
            startItem.target = self
            startItem.isEnabled = !viewModel.isStartingDaemon
            menu.addItem(startItem)
        }

        menu.addItem(.separator())

        // 2. Windows
        let openConsole = NSMenuItem(title: "打开控制台", action: #selector(openConsoleFromMenu), keyEquivalent: "o")
        openConsole.target = self
        menu.addItem(openConsole)

        let openPlayground = NSMenuItem(title: "打开演练台", action: #selector(openPlaygroundFromMenu), keyEquivalent: "p")
        openPlayground.target = self
        menu.addItem(openPlayground)

        menu.addItem(.separator())

        // 3. Model Quick Controls
        let prewarmRoot = NSMenuItem(title: "预热模型", action: nil, keyEquivalent: "")
        let prewarmSub = NSMenu()
        let stoppedModels = viewModel.models.filter {
            $0.capability != "diarization" && $0.installed && $0.state == "STOPPED"
        }
        if !viewModel.connected || stoppedModels.isEmpty {
            let empty = NSMenuItem(
                title: viewModel.connected ? "无待预热模型" : "服务未连接",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            prewarmSub.addItem(empty)
        } else {
            for model in stoppedModels {
                let item = NSMenuItem(
                    title: model.displayName,
                    action: #selector(prewarmModelFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = model.id
                item.isEnabled = !viewModel.pendingModelIds.contains(model.id)
                prewarmSub.addItem(item)
            }
        }
        prewarmRoot.submenu = prewarmSub
        menu.addItem(prewarmRoot)

        let activeRoot = NSMenuItem(title: "活跃模型", action: nil, keyEquivalent: "")
        let activeSub = NSMenu()
        let loadedModels = viewModel.models.filter {
            $0.capability != "diarization" && $0.state != "STOPPED"
        }
        if !viewModel.connected || loadedModels.isEmpty {
            let empty = NSMenuItem(
                title: viewModel.connected ? "当前无已载入模型" : "服务未连接",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            activeSub.addItem(empty)
        } else {
            for model in loadedModels {
                let modelItem = NSMenuItem(
                    title: "\(model.displayName) (\(model.memory.totalMB) MB)",
                    action: nil,
                    keyEquivalent: ""
                )
                let modelMenu = NSMenu()

                let unloadItem = NSMenuItem(
                    title: "卸载模型",
                    action: #selector(unloadModelFromMenu(_:)),
                    keyEquivalent: ""
                )
                unloadItem.target = self
                unloadItem.representedObject = model.id
                unloadItem.isEnabled = !viewModel.pendingModelIds.contains(model.id)
                modelMenu.addItem(unloadItem)

                let pinItem = NSMenuItem(
                    title: "常驻内存",
                    action: #selector(togglePinModelFromMenu(_:)),
                    keyEquivalent: ""
                )
                pinItem.target = self
                pinItem.representedObject = model.id
                pinItem.state = model.pinPolicy == "pinned" ? .on : .off
                modelMenu.addItem(pinItem)

                modelItem.submenu = modelMenu
                activeSub.addItem(modelItem)
            }
        }
        activeRoot.submenu = activeSub
        menu.addItem(activeRoot)

        let unloadAllItem = NSMenuItem(
            title: "释放空闲内存",
            action: #selector(unloadAllFromMenu),
            keyEquivalent: "k"
        )
        unloadAllItem.keyEquivalentModifierMask = [.command, .shift]
        unloadAllItem.target = self
        unloadAllItem.isEnabled = viewModel.connected && !viewModel.isUnloadingAll
        menu.addItem(unloadAllItem)

        menu.addItem(.separator())

        // 4. Connectivity & Auth (Alt reveals Bearer Token)
        let endpoint = viewModel.config?.mdnsBaseUrl
            ?? viewModel.discovery?.mdnsBaseUrl
            ?? viewModel.discovery?.httpBaseUrl
            ?? "http://acpm.local:18790"
        let copyApi = NSMenuItem(
            title: "复制 API 地址 (\(endpoint.replacingOccurrences(of: "http://", with: "")))",
            action: #selector(copyApiEndpointFromMenu),
            keyEquivalent: "c"
        )
        copyApi.keyEquivalentModifierMask = [.command]
        copyApi.target = self
        menu.addItem(copyApi)

        let copyToken = NSMenuItem(
            title: "复制 Bearer Token",
            action: #selector(copyTokenFromMenu),
            keyEquivalent: "c"
        )
        copyToken.keyEquivalentModifierMask = [.command, .option]
        copyToken.isAlternate = true
        copyToken.target = self
        copyToken.isEnabled = viewModel.discovery != nil
        menu.addItem(copyToken)

        menu.addItem(.separator())

        // 5. Preferences
        let loginItem = NSMenuItem(
            title: "登录时启动",
            action: #selector(toggleLoginItemFromMenu),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = viewModel.loginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let appearanceRoot = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let appearanceSub = NSMenu()
        for mode in AppAppearance.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectAppearanceFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = viewModel.appearance == mode ? .on : .off
            appearanceSub.addItem(item)
        }
        appearanceRoot.submenu = appearanceSub
        menu.addItem(appearanceRoot)

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // 6. Lifecycle & Diagnostics (Alt reveals Export Diagnostics)
        let restartItem = NSMenuItem(
            title: viewModel.isRestartingDaemon ? "正在重启 AI 服务…" : "重启 AI 服务",
            action: #selector(restartServiceFromMenu),
            keyEquivalent: ""
        )
        restartItem.target = self
        restartItem.isEnabled = !viewModel.isRestartingDaemon
        menu.addItem(restartItem)

        let exportDiag = NSMenuItem(
            title: "导出诊断包…",
            action: #selector(exportDiagnosticsFromMenu),
            keyEquivalent: ""
        )
        exportDiag.keyEquivalentModifierMask = [.option]
        exportDiag.isAlternate = true
        exportDiag.target = self
        menu.addItem(exportDiag)

        let aboutItem = NSMenuItem(
            title: "关于 \(AcpmTheme.productName)",
            action: #selector(openAboutFromMenu),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "退出 \(AcpmTheme.productName)",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Window Lifecycle & Activation Policy

    func showConsoleWindow(tab: ConsoleTab? = nil, openOnboarding: Bool = false) {
        closePopover()
        if let tab {
            viewModel.selectedTab = tab
        }
        if openOnboarding {
            viewModel.openOnboarding()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        if consoleWindow == nil {
            let root = ConsoleWindowView(
                viewModel: viewModel,
                onOpenSettings: { [weak self] in
                    self?.showSettingsWindow()
                }
            )
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = AcpmTheme.productName
            win.toolbarStyle = .unified
            win.minSize = NSSize(width: 960, height: 640)
            win.isReleasedWhenClosed = false
            win.contentViewController = hosting
            win.delegate = self
            win.center()
            consoleWindow = win
        }

        consoleWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettingsWindow() {
        closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        if settingsWindow == nil {
            let root = SettingsView(
                viewModel: viewModel,
                onOpenOnboarding: { [weak self] in
                    self?.showConsoleWindow(tab: .overview, openOnboarding: true)
                }
            )
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 470),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "\(AcpmTheme.productName) 设置"
            win.isReleasedWhenClosed = false
            win.contentViewController = hosting
            win.delegate = self
            win.center()
            settingsWindow = win
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let consoleOpen = self.consoleWindow?.isVisible ?? false
            let settingsOpen = self.settingsWindow?.isVisible ?? false
            if !consoleOpen && !settingsOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func confirmAndQuitIfNeeded() -> NSApplication.TerminateReply {
        closePopover()
        guard viewModel.connected else {
            viewModel.stopMonitoring()
            viewModel.audioPreviewer.stop()
            viewModel.daemonSupervisor.stopManagedDaemonIfOwned()
            return .terminateNow
        }

        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出 \(AcpmTheme.productName)？"
        alert.informativeText = viewModel.hasActiveRuntimeWork
            ? "当前仍有活跃模型或正在处理的任务。退出会停止本地 AI 服务，言墨输入法将暂时无法使用本地纠错与语音识别。"
            : "退出将停止本地 AI 服务，言墨输入法将暂时无法使用本地纠错与语音识别。"
        alert.addButton(withTitle: "仅关闭窗口")
        let quitBtn = alert.addButton(withTitle: "退出并停止服务")
        quitBtn.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            consoleWindow?.close()
            settingsWindow?.close()
            NSApp.setActivationPolicy(.accessory)
            return .terminateCancel
        case .alertSecondButtonReturn:
            viewModel.stopMonitoring()
            viewModel.audioPreviewer.stop()
            viewModel.daemonSupervisor.stopManagedDaemonIfOwned()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func exportDiagnosticsWithSavePanel() {
        closePopover()
        guard let data = viewModel.exportRedactedDiagnosticsJSON() else {
            viewModel.showToast("生成诊断包失败", kind: .error)
            return
        }
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "acpm-diagnostics.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                viewModel.showToast("已导出脱敏诊断包：\(url.lastPathComponent)", kind: .success)
            } catch {
                viewModel.showToast("写入诊断文件失败：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    // MARK: - NSMenu Actions

    @objc private func startServiceFromMenu() {
        Task { await viewModel.ensureDaemonRunningAndRefresh() }
    }

    @objc private func openConsoleFromMenu() {
        showConsoleWindow()
    }

    @objc private func openPlaygroundFromMenu() {
        showConsoleWindow(tab: .playground)
    }

    @objc private func prewarmModelFromMenu(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }
        Task { await viewModel.loadModel(modelId) }
    }

    @objc private func unloadModelFromMenu(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }
        Task { await viewModel.unloadModel(modelId) }
    }

    @objc private func togglePinModelFromMenu(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }
        let nextPolicy = sender.state == .on ? "auto" : "pinned"
        Task { await viewModel.updateModelConfig(modelId, pinPolicy: nextPolicy) }
    }

    @objc private func unloadAllFromMenu() {
        Task { await viewModel.unloadAll() }
    }

    @objc private func copyApiEndpointFromMenu() {
        let endpoint = viewModel.config?.mdnsBaseUrl
            ?? viewModel.discovery?.mdnsBaseUrl
            ?? viewModel.discovery?.httpBaseUrl
            ?? "http://acpm.local:18790"
        viewModel.copyToPasteboard(endpoint, notice: "已复制 API 地址")
    }

    @objc private func copyTokenFromMenu() {
        guard let token = viewModel.discovery?.token else { return }
        viewModel.copyToPasteboard(token, notice: "已复制 Bearer Token")
    }

    @objc private func toggleLoginItemFromMenu() {
        viewModel.loginItem.setEnabled(!viewModel.loginItem.isEnabled)
    }

    @objc private func selectAppearanceFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let next = AppAppearance(rawValue: raw)
        else { return }
        viewModel.appearance = next
        updateStatusItemAppearance()
    }

    @objc private func openSettingsFromMenu() {
        showSettingsWindow()
    }

    @objc private func restartServiceFromMenu() {
        Task { await viewModel.restartDaemon() }
    }

    @objc private func exportDiagnosticsFromMenu() {
        exportDiagnosticsWithSavePanel()
    }

    @objc private func openAboutFromMenu() {
        closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
}

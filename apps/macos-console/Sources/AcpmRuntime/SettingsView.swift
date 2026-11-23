import AcpmClient
import AcpmRuntimeCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var viewModel: RuntimeViewModel
    let onOpenOnboarding: () -> Void

    @State private var budgetTierSelection = "balanced"
    @State private var customBudgetEnabled = false
    @State private var customBudgetGB = 16
    @State private var showTierSaved = false
    @State private var showOverrideSaved = false
    @State private var snippetKind: SnippetKind = .curl

    private enum SnippetKind: String, CaseIterable, Identifiable {
        case curl = "curl"
        case python = "Python SDK"
        case swift = "Swift SDK"

        var id: String { rawValue }
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }

            memoryTab
                .tabItem { Label("内存", systemImage: "memorychip") }

            connectivityTab
                .tabItem { Label("连接", systemImage: "network") }

            advancedTab
                .tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
        }
        .padding(AcpmTheme.Spacing.l)
        .frame(width: 620, height: 450)
        .onAppear { syncFromConfig() }
        .onChange(of: viewModel.config?.budgetTier) { _, _ in syncFromConfig() }
        .onChange(of: viewModel.config?.budgetOverrideMb) { _, _ in syncFromConfig() }
    }

    private var generalTab: some View {
        Form {
            Section("外观主题") {
                LabeledContent("界面外观") {
                    Picker("", selection: $viewModel.appearance) {
                        ForEach(AppAppearance.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
            }

            Section("系统集成") {
                Toggle(
                    "登录 macOS 时自动启动 \(AcpmTheme.productName)",
                    isOn: Binding(
                        get: { viewModel.loginItem.isEnabled },
                        set: { viewModel.loginItem.setEnabled($0) }
                    )
                )

                LabeledContent("自启动状态") {
                    Text(viewModel.loginItem.statusDescription)
                        .foregroundStyle(.secondary)
                }

                if let err = viewModel.loginItem.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("快速引导") {
                LabeledContent("本地模型扫描向导") {
                    Button("打开配置向导…") {
                        onOpenOnboarding()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var memoryTab: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: AcpmTheme.Spacing.s) {
                        Picker("", selection: $budgetTierSelection) {
                            Text("节能").tag("eco")
                            Text("均衡").tag("balanced")
                            Text("性能").tag("performance")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                        .onChange(of: budgetTierSelection) { _, next in
                            guard next != viewModel.config?.budgetTier else { return }
                            Task {
                                let ok = await viewModel.updateBudgetTier(next, silent: true)
                                if ok {
                                    customBudgetEnabled = false
                                    flashSaved($showTierSaved)
                                }
                            }
                        }

                        InlineSavedBadge(visible: showTierSaved)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("运行档位")
                        Text("更改后立即生效")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    HStack(spacing: AcpmTheme.Spacing.m) {
                        Toggle("", isOn: $customBudgetEnabled)
                            .labelsHidden()
                            .onChange(of: customBudgetEnabled) { _, enabled in
                                Task {
                                    let mb: UInt64? = enabled ? UInt64(customBudgetGB * 1024) : nil
                                    if await viewModel.updateBudgetOverride(mb: mb, silent: true) {
                                        flashSaved($showOverrideSaved)
                                    }
                                }
                            }

                        if customBudgetEnabled {
                            Stepper(
                                value: $customBudgetGB,
                                in: 4...192,
                                step: 2
                            ) {
                                Text("\(customBudgetGB) GB (\(customBudgetGB * 1024) MB)")
                                    .font(.callout.monospacedDigit())
                            }
                            .onChange(of: customBudgetGB) { _, gb in
                                guard customBudgetEnabled else { return }
                                Task {
                                    if await viewModel.updateBudgetOverride(mb: UInt64(gb * 1024), silent: true) {
                                        flashSaved($showOverrideSaved)
                                    }
                                }
                            }
                        } else {
                            Text("自动跟随档位上限")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        InlineSavedBadge(visible: showOverrideSaved)
                    }
                } label: {
                    Text("自定义内存上限")
                }
            } header: {
                Text("统一内存调度")
            } footer: {
                if let cfg = viewModel.config {
                    Text("当前生效上限：\(cfg.effectiveBudget.totalMB) MB · 主机物理内存：\(viewModel.hardwareRecommendation.ramGB) GB（推荐：\(viewModel.hardwareRecommendation.tier.badgeTitle)）")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!viewModel.connected)
    }

    private var connectivityTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
                if let disc = viewModel.discovery {
                    QuickCopyField(
                        label: "局域网 mDNS",
                        value: disc.mdnsBaseUrl ?? "http://acpm.local:18790",
                        copyValue: disc.mdnsBaseUrl ?? "http://acpm.local:18790"
                    ) { viewModel.copyToPasteboard($0) }

                    QuickCopyField(
                        label: "本机 HTTP",
                        value: disc.httpBaseUrl,
                        copyValue: disc.httpBaseUrl
                    ) { viewModel.copyToPasteboard($0) }

                    QuickCopyField(
                        label: "UDS Socket",
                        value: RuntimeViewModel.abbreviateHomePath(disc.nativeIpcPath),
                        copyValue: disc.nativeIpcPath
                    ) { viewModel.copyToPasteboard($0) }

                    QuickCopyField(
                        label: "Bearer Token",
                        value: disc.token,
                        copyValue: disc.token,
                        isSecret: true
                    ) { viewModel.copyToPasteboard($0) }

                    Divider().padding(.vertical, AcpmTheme.Spacing.xs)

                    VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                        HStack {
                            Text("接入示例")
                                .font(.headline)
                            Spacer()
                            Picker("", selection: $snippetKind) {
                                ForEach(SnippetKind.allCases) { k in
                                    Text(k.rawValue).tag(k)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }

                        QuickCopyField(
                            label: snippetKind.rawValue,
                            value: snippetText(kind: snippetKind, discovery: disc).replacingOccurrences(of: "\n", with: " "),
                            copyValue: snippetText(kind: snippetKind, discovery: disc)
                        ) { viewModel.copyToPasteboard($0) }

                        Text(snippetText(kind: snippetKind, discovery: disc))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(AcpmTheme.Spacing.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius))
                    }
                } else {
                    EmptyStateCard(
                        systemImage: "network.slash",
                        title: "未读取到运行时连接信息",
                        subtitle: "请先启动本地 AI 服务后再查看跨设备接口与 Bearer Token。"
                    )
                }
            }
            .padding(AcpmTheme.Spacing.xs)
        }
    }

    private var advancedTab: some View {
        Form {
            Section("运行数据目录") {
                if let cfg = viewModel.config {
                    LabeledContent("数据目录") {
                        Text(RuntimeViewModel.abbreviateHomePath(cfg.dataDir))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("模型仓库目录") {
                        Text(RuntimeViewModel.abbreviateHomePath(cfg.modelsDir))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("在 Finder 中打开…") {
                            viewModel.openDataDirectoryInFinder()
                        }
                    }
                } else {
                    Text("服务离线，暂无活跃数据目录信息")
                        .foregroundStyle(.secondary)
                }
            }

            Section("维护与诊断") {
                LabeledContent("守护进程控制") {
                    Button(viewModel.isRestartingDaemon ? "正在重启…" : "重启 AI 服务") {
                        Task { await viewModel.restartDaemon() }
                    }
                    .disabled(viewModel.isRestartingDaemon)
                }
                LabeledContent("运行状态导出") {
                    Button("导出脱敏诊断包…") {
                        exportDiagnostics()
                    }
                }
            }

            Section("引擎说明") {
                LabeledContent("语音活动检测 (VAD)") {
                    Text("Pyannote 3.0 CPU ONNX（随包内置）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func syncFromConfig() {
        guard let cfg = viewModel.config else { return }
        if budgetTierSelection != cfg.budgetTier {
            budgetTierSelection = cfg.budgetTier
        }
        if let ovMb = cfg.budgetOverrideMb {
            customBudgetEnabled = true
            customBudgetGB = max(4, Int((Double(ovMb) / 1024.0).rounded()))
        } else {
            customBudgetEnabled = false
        }
    }

    private func flashSaved(_ binding: Binding<Bool>) {
        withAnimation(.easeInOut(duration: 0.2)) {
            binding.wrappedValue = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeInOut(duration: 0.25)) {
                binding.wrappedValue = false
            }
        }
    }

    private func exportDiagnostics() {
        guard let data = viewModel.exportRedactedDiagnosticsJSON() else {
            viewModel.showToast("生成诊断包失败", kind: .error)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "acpm-diagnostics.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                viewModel.showToast("已导出脱敏诊断包：\(url.lastPathComponent)", kind: .success)
            } catch {
                viewModel.showToast("写入失败：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func snippetText(kind: SnippetKind, discovery: RuntimeDiscovery) -> String {
        let endpoint = discovery.mdnsBaseUrl ?? discovery.httpBaseUrl
        switch kind {
        case .curl:
            return """
            curl -sS \(endpoint)/v1/chat/completions \\
              -H "Authorization: Bearer \(discovery.token)" \\
              -H "Content-Type: application/json" \\
              -d '{"model":"yanmo-correct-4b-cot","messages":[{"role":"user","content":"测试纠错"}],"separate_reasoning":true}'
            """
        case .python:
            return """
            from acpm_client import AcpmClient
            client = AcpmClient.from_default_discovery(caller="yanmo-ime")
            print(client.vad("/path/to/audio.wav"))
            """
        case .swift:
            return """
            let client = try AcpmClient.fromDefaultDiscovery(caller: "yanmo-ime")
            let res = try await client.vad(VadRequest(filePath: "/path/to/audio.wav"))
            """
        }
    }
}

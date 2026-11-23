import AcpmClient
import AcpmRuntimeCore
import AppKit
import SwiftUI

struct OnboardingSheetView: View {
    @Bindable var viewModel: RuntimeViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var selectedModelIds: Set<String> = []
    @State private var selectedTier = "balanced"
    @State private var tierSaved = false
    @State private var isAdvancing = false
    @State private var manualTargetModelId = "yanmo-correct-4b-cot"

    private var recommendedDaemonTier: String {
        switch viewModel.hardwareRecommendation.tier {
        case .compact8GB: return "eco"
        case .balanced16GB: return "balanced"
        case .pro24GBPlus: return "performance"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader
            Divider()

            ScrollView {
                Group {
                    switch step {
                    case 0: hardwareStepView
                    case 1: modelDiscoveryStepView
                    default: connectivityStepView
                    }
                }
                .padding(AcpmTheme.Spacing.xl)
            }

            Divider()
            wizardFooter
        }
        .frame(width: 660, height: 520)
        .onAppear {
            let detected = viewModel.scanLocalModels()
            selectedModelIds = Set(detected.map(\.modelId))
            selectedTier = viewModel.config?.budgetTier ?? recommendedDaemonTier
        }
    }

    private var wizardHeader: some View {
        HStack(spacing: AcpmTheme.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(AcpmTheme.brandGradient)
                    .frame(width: 40, height: 40)
                Image(systemName: AcpmTheme.brandSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("欢迎使用 \(AcpmTheme.productName)")
                    .font(.title3.bold())
                Text("三步完成硬件预算匹配、本地模型发现与 mDNS 服务配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                stepDot(index: 0, title: "1. 硬件")
                stepDot(index: 1, title: "2. 模型")
                stepDot(index: 2, title: "3. 连接")
            }
        }
        .padding(.horizontal, AcpmTheme.Spacing.xl)
        .padding(.vertical, AcpmTheme.Spacing.l)
    }

    private func stepDot(index: Int, title: String) -> some View {
        Text(title)
            .font(.caption2.weight(step == index ? .bold : .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                step == index ? AcpmTheme.brandIndigo.opacity(0.18) : Color.primary.opacity(0.06),
                in: Capsule()
            )
            .foregroundStyle(step == index ? AcpmTheme.brandIndigo : .secondary)
    }

    private var hardwareStepView: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.l) {
            GlassCard(tint: AcpmTheme.brandIndigo) {
                VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                    HStack {
                        Label("Apple Silicon 硬件自检", systemImage: "cpu")
                            .font(.headline)
                        Spacer()
                        StatusPill(
                            label: "\(viewModel.hardwareRecommendation.ramGB) GB 统一内存",
                            color: AcpmTheme.brandIndigo,
                            systemImage: "memorychip"
                        )
                    }
                    Text("推荐调度档位：\(viewModel.hardwareRecommendation.tier.badgeTitle)")
                        .font(.subheadline.weight(.semibold))
                    Text(viewModel.hardwareRecommendation.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        ForEach(viewModel.hardwareRecommendation.recommendedModels, id: \.self) { m in
                            Text(verbatim: m)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, AcpmTheme.Spacing.s)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }

            GlassCard {
                HStack(spacing: AcpmTheme.Spacing.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("选择统一内存运行档位")
                            .font(.subheadline.weight(.semibold))
                        Text("切换后立即生效，后续可在设置中随时更改")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    InlineSavedBadge(visible: tierSaved)

                    Picker("档位", selection: $selectedTier) {
                        Text("节能").tag("eco")
                        Text("均衡").tag("balanced")
                        Text("性能").tag("performance")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .disabled(!viewModel.connected)
                    .onChange(of: selectedTier) { _, next in
                        Task {
                            if await viewModel.updateBudgetTier(next, silent: true) {
                                withAnimation { tierSaved = true }
                                try? await Task.sleep(for: .seconds(1.5))
                                withAnimation { tierSaved = false }
                            }
                        }
                    }
                }
            }
        }
    }

    private var modelDiscoveryStepView: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("智能扫描并绑定本地模型权重")
                        .font(.headline)
                    Text("已自动检测 ~/.cache/codex 与 HuggingFace 缓存；Pyannote CPU VAD 已随应用内置开箱即用。勾选后点击「下一步」自动绑定。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let rescanned = viewModel.scanLocalModels()
                    selectedModelIds = Set(rescanned.map(\.modelId))
                } label: {
                    Label("重新扫描", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if viewModel.detectedLocalModels.isEmpty {
                EmptyStateCard(
                    systemImage: "externaldrive.badge.questionmark",
                    title: "暂未扫描到预置缓存目录",
                    subtitle: "您可通过下方「选择文件夹…」手动指定权重目录，或在「模型」页面在线下载。"
                )
            } else {
                ForEach(viewModel.detectedLocalModels) { item in
                    let isSelected = selectedModelIds.contains(item.modelId)
                    GlassCard(padding: AcpmTheme.Spacing.m) {
                        HStack(spacing: AcpmTheme.Spacing.m) {
                            Toggle("", isOn: Binding(
                                get: { isSelected },
                                set: { checked in
                                    if checked { selectedModelIds.insert(item.modelId) }
                                    else { selectedModelIds.remove(item.modelId) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                            CapabilityBadge(capability: item.capability)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    if let q = item.detectedQuant {
                                        Text(q)
                                            .font(.caption2.monospaced())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.14), in: Capsule())
                                            .foregroundStyle(.green)
                                    }
                                    Text(item.sourceLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(RuntimeViewModel.abbreviateHomePath(item.path))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                    }
                }
            }

            GlassCard(padding: AcpmTheme.Spacing.m) {
                HStack(spacing: AcpmTheme.Spacing.m) {
                    Picker("手动绑定", selection: $manualTargetModelId) {
                        ForEach(viewModel.models.filter { $0.capability != "diarization" }) { m in
                            Text(m.displayName).tag(m.id)
                        }
                    }
                    .frame(maxWidth: 300)

                    Spacer()

                    Button("选择文件夹…") {
                        pickFolderAndBind(modelId: manualTargetModelId)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var connectivityStepView: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
            GlassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("登录时自动启动后台引擎 (SMAppService)")
                            .font(.subheadline.weight(.semibold))
                        Text("开机静默启动本地服务，言墨输入法随叫随用 · \(viewModel.loginItem.statusDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { viewModel.loginItem.isEnabled },
                        set: { viewModel.loginItem.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            if let disc = viewModel.discovery {
                GlassCard {
                    VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                        Label("跨设备接入与鉴权信息", systemImage: "bonjour")
                            .font(.headline)

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
                            label: "Bearer Token",
                            value: disc.token,
                            copyValue: disc.token,
                            isSecret: true
                        ) { viewModel.copyToPasteboard($0) }
                    }
                }
            }

            GlassCard(tint: .teal) {
                HStack(spacing: AcpmTheme.Spacing.m) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title2)
                        .foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("一切就绪！点击完成立即跳转至「演练台」")
                            .font(.subheadline.weight(.semibold))
                        Text("可直接实测 4B 思维链纠错、CPU VAD + ASR 与音色克隆。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var wizardFooter: some View {
        HStack {
            if step > 0 {
                Button("上一步") {
                    withAnimation { step -= 1 }
                }
                .buttonStyle(.bordered)
            } else {
                Button("稍后配置") {
                    viewModel.completeOnboarding(navigateToPlayground: false)
                    dismiss()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if step < 2 {
                Button(isAdvancing ? "正在应用…" : "下一步") {
                    advanceStep()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAdvancing)
            } else {
                Button("完成并进入演练台") {
                    viewModel.completeOnboarding(navigateToPlayground: true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, AcpmTheme.Spacing.xl)
        .padding(.vertical, AcpmTheme.Spacing.m)
    }

    private func advanceStep() {
        if step == 1 && viewModel.connected {
            let chosen = viewModel.detectedLocalModels.filter { selectedModelIds.contains($0.modelId) }
            if !chosen.isEmpty {
                isAdvancing = true
                Task {
                    _ = await viewModel.bindDetectedModels(chosen, silent: true)
                    isAdvancing = false
                    withAnimation { step += 1 }
                }
                return
            }
        }
        withAnimation { step += 1 }
    }

    private func pickFolderAndBind(modelId: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 \(modelId) 的本地权重目录"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                _ = await viewModel.updateModelPath(modelId, path: url.path)
                _ = viewModel.scanLocalModels()
            }
        }
    }
}

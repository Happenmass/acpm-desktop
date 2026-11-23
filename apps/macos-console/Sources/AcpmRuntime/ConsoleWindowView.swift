import AcpmClient
import AcpmRuntimeCore
import SwiftUI

struct ConsoleWindowView: View {
    @Bindable var viewModel: RuntimeViewModel
    let onOpenSettings: () -> Void

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarBrandHeader
                    .padding(.horizontal, AcpmTheme.Spacing.m)
                    .padding(.vertical, AcpmTheme.Spacing.m)

                List(
                    ConsoleTab.allCases,
                    selection: Binding<ConsoleTab?>(
                        get: { viewModel.selectedTab },
                        set: { if let tab = $0 { viewModel.selectedTab = tab } }
                    )
                ) { tab in
                    HStack {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                        Spacer()
                        if let badge = attentionBadgeCount(for: tab), badge > 0 {
                            Text(verbatim: "\(badge)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(attentionBadgeColor(for: tab).opacity(0.18), in: Capsule())
                                .foregroundStyle(attentionBadgeColor(for: tab))
                        }
                    }
                    .tag(tab)
                }
                .listStyle(.sidebar)

                Divider()
                sidebarConnectionFooter
                    .padding(AcpmTheme.Spacing.m)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 245)
        } detail: {
            ZStack(alignment: .bottom) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))

                if let toast = viewModel.toast {
                    ToastOverlay(toast: toast) {
                        viewModel.dismissToast()
                    }
                    .padding(.bottom, AcpmTheme.Spacing.l)
                    .padding(.horizontal, AcpmTheme.Spacing.l)
                }
            }
            .animation(.snappy(duration: 0.28), value: viewModel.toast)
            .navigationTitle(viewModel.selectedTab.rawValue)
            .navigationSubtitle(liveSubtitle)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StatusPill(
                    label: viewModel.isStartingDaemon
                        ? "启动中"
                        : (viewModel.connected ? "运行中" : "离线"),
                    color: viewModel.connected ? .green : (viewModel.isStartingDaemon ? .orange : .red),
                    pulsing: viewModel.isStartingDaemon
                )

                Button {
                    Task { await viewModel.unloadAll() }
                } label: {
                    if viewModel.isUnloadingAll {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("释放中…")
                        }
                    } else {
                        Label("释放内存", systemImage: "memorychip")
                    }
                }
                .labelStyle(.titleAndIcon)
                .disabled(!viewModel.connected || viewModel.isUnloadingAll)
                .help("释放所有未常驻的空闲模型内存 (⇧⌘K)")

                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("打开设置 (⌘,)")
            }
        }
        .sheet(isPresented: $viewModel.showOnboardingSheet) {
            OnboardingSheetView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.startMonitoring()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch viewModel.selectedTab {
        case .overview:
            ScrollView {
                OverviewTabView(viewModel: viewModel)
                    .padding(AcpmTheme.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .models:
            ModelsTabView(viewModel: viewModel)
        case .playground:
            ScrollView {
                PlaygroundTabView(viewModel: viewModel)
                    .padding(AcpmTheme.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .jobs:
            ScrollView {
                JobsTabView(viewModel: viewModel)
                    .padding(AcpmTheme.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .voices:
            ScrollView {
                VoicesTabView(viewModel: viewModel)
                    .padding(AcpmTheme.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var liveSubtitle: String {
        switch viewModel.selectedTab {
        case .overview:
            if let st = viewModel.status {
                let usedGB = String(format: "%.1f", Double(st.used.totalMB) / 1024.0)
                let budgetGB = String(format: "%.0f", Double(max(st.budget.totalMB, 1024)) / 1024.0)
                return "\(usedGB) / \(budgetGB) GB 统一内存 · 活跃请求 \(st.activeRequests)"
            }
            return "\(viewModel.hardwareRecommendation.ramGB) GB Apple Silicon"
        case .models:
            let available = viewModel.models.filter { $0.capability != "diarization" }
            let loaded = available.filter { $0.state != "STOPPED" }.count
            return "\(available.count) 个模型 · \(loaded) 个已载入"
        case .playground:
            return "本地实时流式测试"
        case .jobs:
            let running = viewModel.batches.filter { $0.status == .running || $0.status == .queued }.count
            return running > 0 ? "\(running) 个进行中批量任务" : "事件流实时监听中"
        case .voices:
            return "\(viewModel.voices.count) 个参考音色"
        }
    }

    private var sidebarBrandHeader: some View {
        HStack(spacing: AcpmTheme.Spacing.s) {
            Image(systemName: AcpmTheme.brandSymbol)
                .font(.title3)
                .foregroundStyle(AcpmTheme.brandGradient)
            Text(AcpmTheme.productName)
                .font(.headline)
            Spacer()
        }
    }

    private var sidebarConnectionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = viewModel.status {
                HStack {
                    Text("内存 \(status.used.totalMB) MB")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .contentTransition(.numericText())
                    Spacer()
                    Text(verbatim: "PID \(status.pid)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(
                    value: Double(min(status.used.totalMB, max(status.budget.totalMB, 1))),
                    total: Double(max(status.budget.totalMB, 1))
                )
                .controlSize(.small)
                .tint(AcpmTheme.pressureColor(status.memoryPressure))
            } else {
                Text("本地服务离线")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func attentionBadgeCount(for tab: ConsoleTab) -> Int? {
        switch tab {
        case .overview:
            return viewModel.recentFailures.isEmpty ? nil : viewModel.recentFailures.count
        case .jobs:
            let batches = viewModel.batches.filter { $0.status == .running || $0.status == .queued || $0.status == .paused }.count
            let dls = viewModel.downloads.values.filter { $0.status == .downloading || $0.status == .verifying || $0.status == .queued }.count
            let sum = batches + dls
            return sum > 0 ? sum : nil
        case .models, .playground, .voices:
            return nil
        }
    }

    private func attentionBadgeColor(for tab: ConsoleTab) -> Color {
        switch tab {
        case .overview: return .orange
        case .jobs: return .purple
        default: return .secondary
        }
    }
}

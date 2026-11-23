import AcpmClient
import SwiftUI

struct ConsoleWindowView: View {
    @Bindable var viewModel: RuntimeViewModel

    var body: some View {
        NavigationSplitView {
            List(ConsoleTab.allCases, selection: Binding<ConsoleTab?>(
                get: { viewModel.selectedTab },
                set: { if let tab = $0 { viewModel.selectedTab = tab } }
            )) { tab in
                Text(tab.rawValue)
                    .tag(tab)
            }
            .navigationTitle("AI SDK")
        } detail: {
            Group {
                switch viewModel.selectedTab {
                case .overview:
                    overviewTab
                case .models:
                    modelsTab
                case .jobs:
                    jobsTab
                case .voicesAndSettings:
                    voicesAndSettingsTab
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("运行时概览")
                    .font(.title2.bold())
                Spacer()
                Button("刷新") {
                    Task { await viewModel.refresh() }
                }
            }

            if let status = viewModel.status {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow {
                        statCard(title: "平台", value: status.platform)
                        statCard(title: "预算 / 已用", value: "\(status.used.totalMB) / \(status.budget.totalMB) MB")
                        statCard(title: "内存压力", value: status.memoryPressure)
                        statCard(title: "热状态", value: status.thermalState)
                    }
                }
            } else {
                Text(viewModel.lastErrorMessage ?? "等待连接到 acpmd...")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("最近推理失败记录（已脱敏，不含音频与文本）")
                .font(.headline)
            if viewModel.recentFailures.isEmpty {
                Text("暂无失败记录")
                    .foregroundStyle(.secondary)
            } else {
                List(viewModel.recentFailures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(failure.operation) · \(failure.code.rawValue)")
                            .font(.subheadline.bold())
                        Text("req=\(failure.requestId) stage=\(failure.stage) detail=\(failure.detail) (\(failure.elapsedMs) ms)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var modelsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("逻辑模型管理")
                .font(.title2.bold())
            List(viewModel.models) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayName)
                            .font(.headline)
                        Text("\(model.id) · 能力: \(model.capability) · 状态: \(model.state) · 占用: \(model.memory.totalMB) MB")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.state == "STOPPED" {
                        Button("预热") {
                            Task { await viewModel.loadModel(model.id) }
                        }
                    } else {
                        Button("卸载") {
                            Task { await viewModel.unloadModel(model.id) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var jobsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("活跃任务与批量队列")
                .font(.title2.bold())
            if let status = viewModel.status {
                Text("进行中请求: \(status.activeRequests) · 排队中请求: \(status.queuedRequests)")
                    .font(.body.monospacedDigit())
            } else {
                Text("暂无队列状态")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var voicesAndSettingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音色库与系统设置")
                .font(.title2.bold())
            Text("Phase 2/3 将在此处接入参考音色库试听、内存预算档位（Eco/Balanced/Performance）、模型存储迁移与 SMAppService 开机自启配置。")
                .foregroundStyle(.secondary)
        }
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospaced())
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

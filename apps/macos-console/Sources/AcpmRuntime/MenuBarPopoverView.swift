import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    @Bindable var viewModel: RuntimeViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI SDK")
                        .font(.headline)
                    Text(viewModel.connected ? "acpmd 运行中" : "未连接到 acpmd")
                        .font(.caption)
                        .foregroundStyle(viewModel.connected ? .green : .secondary)
                }
                Spacer()
                if let pressure = viewModel.status?.memoryPressure {
                    Text(pressure.uppercased())
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            if let status = viewModel.status {
                let used = Double(status.used.totalMB) / 1024.0
                let budget = max(Double(status.budget.totalMB) / 1024.0, 0.1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("内存占用")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.2f / %.1f GB", used, budget))
                            .font(.caption.monospacedDigit())
                    }
                    ProgressView(value: min(used, budget), total: budget)
                }
            }

            Divider()

            let active = viewModel.models.filter { $0.state != "STOPPED" }
            if active.isEmpty {
                Text("当前无常驻模型，空闲内存占用极低")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(active) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.displayName)
                                .font(.caption.bold())
                            Text("\(model.state) · \(model.memory.totalMB) MB")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("卸载") {
                            Task { await viewModel.unloadModel(model.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            Divider()

            HStack {
                Button("全部释放") {
                    Task { await viewModel.unloadAll() }
                }
                .disabled(!viewModel.connected)

                Spacer()

                Button("运行控制台") {
                    openWindow(id: "console")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                Spacer()
                Button("退出运行时") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .task {
            await viewModel.refresh()
        }
    }
}

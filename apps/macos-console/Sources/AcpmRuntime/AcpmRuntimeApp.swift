import AcpmRuntimeCore
import SwiftUI

@main
struct AcpmRuntimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                viewModel: appDelegate.viewModel,
                onOpenOnboarding: {
                    appDelegate.statusBarController?.showConsoleWindow(tab: .overview, openOnboarding: true)
                }
            )
            .preferredColorScheme(appDelegate.viewModel.appearance.colorScheme)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    appDelegate.statusBarController?.showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("控制台") {
                Button("概览") {
                    appDelegate.statusBarController?.showConsoleWindow(tab: .overview)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("模型管理") {
                    appDelegate.statusBarController?.showConsoleWindow(tab: .models)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("实时演练台") {
                    appDelegate.statusBarController?.showConsoleWindow(tab: .playground)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("任务与事件") {
                    appDelegate.statusBarController?.showConsoleWindow(tab: .jobs)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("音色库") {
                    appDelegate.statusBarController?.showConsoleWindow(tab: .voices)
                }
                .keyboardShortcut("5", modifiers: .command)

                Divider()

                Button("打开控制台") {
                    appDelegate.statusBarController?.showConsoleWindow()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("打开演练台") {
                    appDelegate.statusBarController?.showConsoleWindow(tab: .playground)
                }
                .keyboardShortcut("p", modifiers: .command)

                Divider()

                Button("立即刷新状态") {
                    Task { await appDelegate.viewModel.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("释放空闲模型内存") {
                    Task { await appDelegate.viewModel.unloadAll() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!appDelegate.viewModel.connected || appDelegate.viewModel.isUnloadingAll)
            }

            CommandGroup(replacing: .help) {
                Button("快速配置向导…") {
                    appDelegate.statusBarController?.showConsoleWindow(tab: .overview, openOnboarding: true)
                }
                Button("导出脱敏诊断包…") {
                    appDelegate.statusBarController?.exportDiagnosticsWithSavePanel()
                }
            }
        }
    }
}

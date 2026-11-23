import SwiftUI

@main
struct AcpmRuntimeApp: App {
    @State private var viewModel = RuntimeViewModel()

    var body: some Scene {
        MenuBarExtra("AI SDK", systemImage: "cpu") {
            MenuBarPopoverView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        Window("AI SDK 运行控制台", id: "console") {
            ConsoleWindowView(viewModel: viewModel)
                .frame(minWidth: 780, minHeight: 540)
        }
    }
}

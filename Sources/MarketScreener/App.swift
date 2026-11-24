import AppKit
import SwiftUI


struct EquityScreenerApp: App {
    @State private var store = ScreenerStore()

    var body: some Scene {
        // A single window (reopened from the menu bar list rather than duplicated).
        Window("Public Equity Screener", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1380, minHeight: 860)
                .task { store.startAutoRefresh() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1600, height: 960)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Data") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                Divider()
                Button("Edit Universe…") { NSWorkspace.shared.open(Universe.fileURL(for: store.universeKind)) }
                Button("Reload Universe") { Task { await store.reloadUniverse() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            PicksMenu().environment(store)
        } label: {
            Image(systemName: "chart.line.downtrend.xyaxis")
            if let top = store.topPicks.first { Text(top.symbol) }
        }
        .menuBarExtraStyle(.window)
    }
}

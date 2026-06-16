import SwiftUI

/// Scene identifier for the Help window. Shared between the `Window`
/// declaration in `File13App` and the `openWindow` call in
/// `HelpCommands`.
let HelpWindowID = "file13.help"

/// Replaces the default macOS Help menu with a single **File13 Help**
/// item that opens the Help window. Lives in its own `Commands` struct
/// so it can read `@Environment(\.openWindow)` — the `.commands`
/// closure on `Scene` isn't a view context.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("File13 Help") {
                openWindow(id: HelpWindowID)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// The File13 Help window. A standalone scene the user can keep open
/// next to the main inbox while triaging. Sidebar lists topics grouped
/// by section, content pane renders the selected topic.
struct HelpWindowView: View {
    @State private var selection: HelpTopic = .welcome
    @State private var search: String = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            HelpContentView(topic: selection)
                .id(selection)
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(visibleSections, id: \.self) { section in
                Section(section.title) {
                    ForEach(visibleTopics(in: section)) { topic in
                        Label(topic.title, systemImage: topic.symbol)
                            .tag(topic)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search help")
    }

    private var visibleSections: [HelpTopic.Section] {
        HelpTopic.Section.allCases.filter { !visibleTopics(in: $0).isEmpty }
    }

    private func visibleTopics(in section: HelpTopic.Section) -> [HelpTopic] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = HelpTopic.allCases.filter { $0.section == section }
        guard !trimmed.isEmpty else { return all }
        let needle = trimmed.lowercased()
        return all.filter { $0.searchHaystack.lowercased().contains(needle) }
    }
}

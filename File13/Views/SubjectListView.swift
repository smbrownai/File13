import File13Core
import SwiftUI

struct SubjectListView: View {
    @Bindable var store: InboxStore

    var body: some View {
        // AppKit-backed table (see `SubjectTable.swift`). The SwiftUI
        // `LazyVStack` rendering of cluster rows kept hitting the centering
        // trap on narrow windows; dropping to `NSTableView` gives us the
        // same "user-resizable columns + Subject absorbs leftover width"
        // story the senders view already has. Keyboard nav (arrows, space)
        // comes from NSTableView natively, so we lose the explicit
        // `.onKeyPress` plumbing the old SwiftUI version needed.
        SubjectTable(store: store, clusters: store.subjectClusters)
            .background(Color(nsColor: .textBackgroundColor))
            .searchable(text: $store.search, placement: .toolbar, prompt: "Search subjects")
    }
}

// `UnreadBadge` and `TriStateCheckbox` below stay in this file because
// `DateListView` and `InspectorView` import them — they live here for
// historical reasons, before `SubjectListView` moved to the AppKit table.
// The old `ColumnHeader` / `ClusterRow` / `ClusterContextMenu` SwiftUI views
// that used to make up this view's body are gone; their AppKit replacements
// live in `SubjectTable.swift`.

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count == 0 {
            Text("—")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        } else {
            Text(count.formatted())
                .monospacedDigit()
                .foregroundStyle(.tint)
                .fontWeight(.semibold)
        }
    }
}

struct TriStateCheckbox: View {
    let isOn: Bool
    let isMixed: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!isOn)
        } label: {
            Image(systemName: symbolName)
                .font(.system(size: 14))
                .foregroundStyle(isOn || isMixed ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.6)))
        }
        .buttonStyle(.plain)
        // Default reading is "button" with no state info. Spell out the
        // tri-state so a non-sighted user can tell whether the cluster is
        // fully selected, partially selected, or empty.
        .accessibilityLabel("Select cluster")
        .accessibilityValue(stateDescription)
    }

    private var symbolName: String {
        if isOn { return "checkmark.square.fill" }
        if isMixed { return "minus.square.fill" }
        return "square"
    }

    private var stateDescription: String {
        if isOn { return "selected" }
        if isMixed { return "partially selected" }
        return "not selected"
    }
}

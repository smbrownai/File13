import AppKit
import SwiftUI

/// Two-pane vertical split (top + bottom, horizontal divider) backed by
/// `NSSplitViewController`.
///
/// We replaced SwiftUI's `VSplitView` here because there's no public way to
/// set the initial divider position on it — the API claims to honor
/// `idealHeight` hints but in practice the splitter falls back to whichever
/// child has a larger intrinsic size, which on the Activity drawer always
/// meant "the inbox wins and the drawer opens at its minimum height."
///
/// `NSSplitViewController` gives us `setPosition(_:ofDividerAt:)` plus the
/// same AppKit-handled smooth drag-resize VSplitView was using under the
/// hood, so we don't regress the responsiveness the original migration
/// from a SwiftUI custom divider was about.
///
/// The bottom pane is conditional: when `showsBottom` is `false` we tear down
/// the bottom `NSSplitViewItem` so the top occupies the whole height with no
/// visible divider.
struct VerticalSplit<Top: View, Bottom: View>: NSViewControllerRepresentable {
    let showsBottom: Bool
    /// Bottom pane's share of total height on the *first* show. User drags
    /// after that take over and `setPosition` isn't called again until the
    /// bottom is re-shown after being hidden.
    var initialBottomRatio: CGFloat = 0.5
    var topMinHeight: CGFloat = 240
    var bottomMinHeight: CGFloat = 140
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    func makeCoordinator() -> Coordinator {
        Coordinator(initialBottomRatio: initialBottomRatio,
                    topMinHeight: topMinHeight,
                    bottomMinHeight: bottomMinHeight)
    }

    func makeNSViewController(context: Context) -> SplitController {
        let svc = SplitController()
        svc.splitView.isVertical = false  // horizontal divider == vertical split
        svc.splitView.dividerStyle = .thin

        let topHost = NSHostingController(rootView: top())
        topHost.sizingOptions = []
        let topItem = NSSplitViewItem(viewController: topHost)
        topItem.minimumThickness = topMinHeight
        topItem.canCollapse = false
        svc.addSplitViewItem(topItem)
        context.coordinator.topHost = topHost

        if showsBottom {
            installBottom(svc: svc, context: context)
        }
        return svc
    }

    func updateNSViewController(_ svc: SplitController, context: Context) {
        // Push the latest SwiftUI subtrees into the hosting controllers so
        // observable state changes propagate normally.
        context.coordinator.topHost?.rootView = top()
        if let bottomHost = context.coordinator.bottomHost {
            bottomHost.rootView = bottom()
        }

        // Toggle the bottom pane in / out as `showsBottom` flips.
        let hasBottom = svc.splitViewItems.count > 1
        switch (showsBottom, hasBottom) {
        case (true, false):
            installBottom(svc: svc, context: context)
        case (false, true):
            if let last = svc.splitViewItems.last {
                svc.removeSplitViewItem(last)
            }
            context.coordinator.bottomHost = nil
        default:
            break
        }

        // Set the initial divider position — must be deferred so the split
        // view has a real height. Reset whenever the bottom was just added
        // so re-showing after a close starts back at the ratio rather than
        // wherever the user last dragged.
        if context.coordinator.needsInitialPositioning, showsBottom {
            let split = svc.splitView
            DispatchQueue.main.async {
                let total = split.bounds.height
                guard total > 0 else { return }
                let dividerPosition = total * (1 - context.coordinator.initialBottomRatio)
                split.setPosition(dividerPosition, ofDividerAt: 0)
                context.coordinator.needsInitialPositioning = false
            }
        }
    }

    private func installBottom(svc: SplitController, context: Context) {
        let bottomHost = NSHostingController(rootView: bottom())
        bottomHost.sizingOptions = []
        let bottomItem = NSSplitViewItem(viewController: bottomHost)
        bottomItem.minimumThickness = bottomMinHeight
        bottomItem.canCollapse = false
        svc.addSplitViewItem(bottomItem)
        context.coordinator.bottomHost = bottomHost
        context.coordinator.needsInitialPositioning = true
    }

    /// We expose a typed subclass mostly so callers don't have to spell out
    /// `NSSplitViewController` in their representable plumbing.
    final class SplitController: NSSplitViewController {}

    @MainActor
    final class Coordinator {
        weak var topHost: NSHostingController<Top>?
        weak var bottomHost: NSHostingController<Bottom>?
        var needsInitialPositioning: Bool = false
        let initialBottomRatio: CGFloat
        let topMinHeight: CGFloat
        let bottomMinHeight: CGFloat

        init(initialBottomRatio: CGFloat, topMinHeight: CGFloat, bottomMinHeight: CGFloat) {
            self.initialBottomRatio = initialBottomRatio
            self.topMinHeight = topMinHeight
            self.bottomMinHeight = bottomMinHeight
        }
    }
}

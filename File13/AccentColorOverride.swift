import AppKit
import File13Core
import ObjectiveC.runtime
import SwiftUI

/// Overrides `NSColor.controlAccentColor` for the entire process so AppKit-
/// rendered things — sidebar selection pills, dialog default buttons, the
/// `Toggle(.switch)` track, NSAlert buttons, focus rings — follow the user's
/// chosen palette. SwiftUI's `.tint()` modifier doesn't reach those: they
/// query `NSColor.controlAccentColor` directly.
///
/// We replace the class getter's IMP with a block that consults a static
/// override, falling back to the saved original IMP when no override is
/// active. This is safer than the `method_exchangeImplementations` /
/// recursive-selector dance: Swift's class-method dispatch on a known class
/// can get inlined, which would cause infinite recursion through the
/// "swizzled" stub.
enum AccentColorOverride {
    private static var didInstall = false
    private static var override: NSColor?
    private static var originalIMP: IMP?

    /// Install the IMP override once. Safe to call repeatedly.
    static func install() {
        guard !didInstall else { return }
        didInstall = true
        let cls: AnyClass = object_getClass(NSColor.self)!  // metaclass
        let selector = #selector(getter: NSColor.controlAccentColor)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        originalIMP = method_getImplementation(method)
        let newIMP = imp_implementationWithBlock(
            { (_: AnyObject) -> NSColor in
                if let o = override { return o }
                guard let saved = originalIMP else { return .controlAccentColor }
                typealias Fn = @convention(c) (AnyObject, Selector) -> NSColor
                let f = unsafeBitCast(saved, to: Fn.self)
                return f(NSColor.self as AnyObject, selector)
            } as @convention(block) (AnyObject) -> NSColor
        )
        method_setImplementation(method, newIMP)
    }

    /// Apply the palette's primary color as the override and force a redraw.
    static func apply(_ palette: SettingsStore.AccentPalette) {
        let nsColor = palette.primaryNSColor
        guard override != nsColor else { return }
        override = nsColor
        // Defer redraw work: at `App.init` time `NSApp` may not yet have any
        // windows mounted, so we touch the window list on the next runloop
        // tick. We deliberately do NOT post a distributed-notification —
        // sandboxed apps can't broadcast system tint-change notifications,
        // and we've seen test-runner connection hangs that correlate with
        // posting them. `setNeedsDisplay` is enough; AppKit re-queries
        // `controlAccentColor` on its next paint.
        DispatchQueue.main.async {
            NSApplication.shared.windows.forEach { $0.contentView?.needsDisplay = true }
        }
    }
}

extension SettingsStore.AccentPalette {
    /// `NSColor` form of `primary`, suitable for AppKit calls. Uses
    /// `NSColor(named:)` for App mode so it tracks light/dark appearance from
    /// the asset catalog.
    var primaryNSColor: NSColor {
        switch self {
        case .app:      NSColor(named: "AccentColor") ?? .controlAccentColor
        case .colorful: .systemBlue
        }
    }
}

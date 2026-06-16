import AppKit
import File13Core
import SwiftUI
import os

/// `NSApplicationDelegate` adaptor for the macOS app. SwiftUI's `App`
/// protocol doesn't expose `applicationShouldTerminate`, which is the
/// only AppKit hook that lets us *defer* termination while async
/// shutdown work finishes — `NSApplication.willTerminateNotification`
/// fires while the app is already exiting and can't await anything.
///
/// What we defer for:
///
///   1. **Commit pending buffered actions.** Delete / Archive / Move
///      hold a 30s undo window during which the IMAP command hasn't
///      been sent. Cmd+Q inside that window used to drop the action —
///      the local cache showed the messages gone, the server still
///      had them, and they reappeared at next launch (confusing).
///      We now commit-on-quit. UX decision recorded in SECURITY.md:
///      silent commit (matches Mail.app / Finder convention; quit is
///      a strong "I'm done" signal — if the user wanted to cancel
///      they'd hit Undo, not Cmd+Q).
///
///   2. **Flush iCloud KV dirty flags.** `CloudKVSyncMirror.flush()`
///      runs on a heartbeat schedule. A quick edit-then-quit could
///      leave dirty keys un-pushed until next launch, delaying
///      multi-Mac sync. The terminate hook pushes them out.
///
/// The inbox and mirror references are injected from
/// `File13App.body` via `.task` after the delegate is constructed
/// (Apple constructs the delegate before our `App.init` runs, so
/// we can't inject at delegate-init time).
@MainActor
final class File13AppDelegate: NSObject, NSApplicationDelegate {

    /// Set from `File13App.body` once the stores exist. Optional
    /// because the delegate's lifecycle starts before the App's.
    var inbox: InboxStore?
    var cloudMirror: CloudKVSyncMirror?

    private static let log = Logger(
        subsystem: "com.shawnbrown.file13",
        category: "ShutdownHooks"
    )

    /// Called by AppKit when the user (or anything else) initiates
    /// termination. Return `.terminateLater` to defer the actual exit
    /// until we've awaited the pending IMAP commit; AppKit waits
    /// up to ~10 seconds before forcing termination, which is plenty
    /// for an IMAP MOVE / EXPUNGE batch on the messages already
    /// queued.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasPending = (inbox?.pendingAction != nil)
        // Fast path: nothing pending, no async work to wait for.
        // We still flush iCloud — `flush()` is synchronous (posts to
        // NSUbiquitousKeyValueStore in-process) so it's safe to run
        // inline before we tell AppKit to proceed.
        if !hasPending {
            cloudMirror?.flush()
            return .terminateNow
        }

        Self.log.info("Quit-time commit hook firing: pending action present, deferring termination")

        Task { @MainActor in
            // Order matters: commit the IMAP action first (the
            // server work that can fail or take seconds), then
            // flush iCloud, then tell AppKit we're done. If the
            // commit throws/cancels, we still want the iCloud
            // flush to fire and the app to exit — never trap the
            // user in a stuck Quit.
            if let inbox = self.inbox {
                await inbox.commitPendingActionImmediately()
                Self.log.info("Quit-time commit hook: pending action committed")
            }
            self.cloudMirror?.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

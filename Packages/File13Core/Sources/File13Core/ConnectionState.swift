import Foundation

/// Lifecycle of an `AccountSession`. Surfaced to UI status indicators in the GUI and to
/// the CLI's `file13 status` command.
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case fetching
    case connected
    case failed(String)
    /// Connect attempt failed but cached headers from a previous run are
    /// available, so the inbox stays populated. The associated message
    /// is the IMAP error so the sidebar can surface it as a tooltip /
    /// VoiceOver label. Distinct from `.connected` because the session
    /// can't issue server-side writes (delete / archive / move would
    /// fail at commit time), and from `.failed` because the user sees
    /// real headers — not an empty inbox.
    case offlineWithCache(String)
}

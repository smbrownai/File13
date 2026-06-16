import Foundation

/// Stable identifier for each help page. Grouped into sections so the sidebar
/// can render dividers without each page needing to know its neighbors.
enum HelpTopic: String, CaseIterable, Identifiable, Hashable {
    case welcome
    case addAccount
    case threeViews
    case cullEmail
    case undoSafety
    case rules
    case aiInsights
    case privacy
    case security
    case shortcuts
    case troubleshooting

    var id: String { rawValue }

    var section: Section {
        switch self {
        case .welcome, .addAccount:
            return .gettingStarted
        case .threeViews, .cullEmail, .undoSafety, .rules, .aiInsights:
            return .using
        case .privacy, .security:
            return .privacyAndSecurity
        case .shortcuts, .troubleshooting:
            return .reference
        }
    }

    var title: String {
        switch self {
        case .welcome:         return "Welcome to File13"
        case .addAccount:      return "Add Your Mail Account"
        case .threeViews:      return "Three Ways to See Your Inbox"
        case .cullEmail:       return "Culling Email"
        case .undoSafety:      return "Undo and Safety Nets"
        case .rules:           return "Rules"
        case .aiInsights:      return "AI Insights"
        case .privacy:         return "Privacy"
        case .security:        return "Security"
        case .shortcuts:       return "Keyboard Shortcuts"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    var symbol: String {
        switch self {
        case .welcome:         return "sparkles"
        case .addAccount:      return "envelope.badge"
        case .threeViews:      return "rectangle.3.group"
        case .cullEmail:       return "scissors"
        case .undoSafety:      return "arrow.uturn.backward.circle"
        case .rules:           return "wand.and.stars"
        case .aiInsights:      return "brain.head.profile"
        case .privacy:         return "hand.raised.fill"
        case .security:        return "lock.fill"
        case .shortcuts:       return "keyboard"
        case .troubleshooting: return "stethoscope"
        }
    }

    /// Plaintext blob used for the sidebar search filter. Kept here (not in
    /// the View builders) so the search can run against every page without
    /// instantiating SwiftUI views.
    var searchHaystack: String {
        title + " " + keywords
    }

    private var keywords: String {
        switch self {
        case .welcome:
            return "intro overview metadata triage"
        case .addAccount:
            return "imap password app-specific gmail icloud outlook yahoo aol provider sign in"
        case .threeViews:
            return "sender subject date view group cluster bucket newsletter"
        case .cullEmail:
            return "delete archive move unsubscribe selection bulk cull clean"
        case .undoSafety:
            return "undo buffer dry run transactional receipt vip protect confirm soft delete trash"
        case .rules:
            return "rule automate filter from subject older move archive delete schedule hourly daily"
        case .aiInsights:
            return "ai apple foundation models openai anthropic google perplexity advisor categorize suggestion"
        case .privacy:
            return "privacy headers body never sent metadata smtp telemetry analytics on-device"
        case .security:
            return "keychain icloud sync sandbox app-group oauth credentials password app-specific"
        case .shortcuts:
            return "keyboard shortcut hotkey command return space delete arrow"
        case .troubleshooting:
            return "error problem fix authentication failed timeout slow sync stuck"
        }
    }

    enum Section: String, CaseIterable, Identifiable {
        case gettingStarted
        case using
        case privacyAndSecurity
        case reference

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gettingStarted:     return "Getting Started"
            case .using:              return "Using File13"
            case .privacyAndSecurity: return "Privacy and Security"
            case .reference:          return "Reference"
            }
        }
    }
}

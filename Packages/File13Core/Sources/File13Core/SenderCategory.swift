import SwiftUI

/// Categorization taxonomy for senders. Kept deliberately small (9 labels) so the LLM picks
/// reliably and the activity dashboard's faceted views stay readable. `other` is the safe
/// fallback when nothing else fits — better than guessing.
public enum SenderCategory: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case personal
    case work
    case finance
    case commerce
    case news
    case social
    case promotional
    case notifications
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .personal:       "Personal"
        case .work:           "Work"
        case .finance:        "Finance"
        case .commerce:       "Shopping"
        case .news:           "News & Newsletters"
        case .social:         "Social"
        case .promotional:    "Promotional"
        case .notifications:  "Notifications"
        case .other:          "Other"
        }
    }

    /// One-line clarification fed to the LLM so it doesn't conflate categories.
    public var promptHint: String {
        switch self {
        case .personal:
            return "1:1 correspondence with a real person — friends, family, colleagues, individual customer support agents writing personally."
        case .work:
            return "Work-related: project tools (Linear, Jira, Asana), team collaboration (Slack, Notion), employer or client communication, work calendars."
        case .finance:
            return "Banks, credit cards, payment processors, billing, investment, tax — anything money-related."
        case .commerce:
            return "Shopping: retailers, marketplaces, order/shipping/delivery confirmations, returns. Includes major brands like Amazon, Etsy, Shopify stores."
        case .news:
            return "Newsletters, blogs, news outlets, magazines, podcasts, content publishers. Anything periodical you subscribe to for content."
        case .social:
            return "Social networks: LinkedIn, Twitter/X, Meta, Reddit, Discord, dating apps. Notifications about people interacting with you online."
        case .promotional:
            return "Marketing, deals, sales, coupons, win-backs, drip campaigns. The point is to sell, not to inform."
        case .notifications:
            return "Automated system alerts: account security, password resets, calendar invites, dev tool alerts (GitHub, CI), uptime monitors. Machine-generated."
        case .other:
            return "Use only when none of the above fits."
        }
    }

    public var symbol: String {
        switch self {
        case .personal:       "person.2"
        case .work:           "briefcase"
        case .finance:        "dollarsign.circle"
        case .commerce:       "bag"
        case .news:           "newspaper"
        case .social:         "heart"
        case .promotional:    "tag"
        case .notifications:  "bell"
        case .other:          "questionmark.circle"
        }
    }

    public var color: Color {
        switch self {
        case .personal:       .green
        case .work:           .blue
        case .finance:        .indigo
        case .commerce:       .purple
        case .news:           .teal
        case .social:         .pink
        case .promotional:    .orange
        case .notifications:  .yellow
        case .other:          .gray
        }
    }
}

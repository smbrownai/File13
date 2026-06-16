import Foundation
import Observation

/// Persists the set of `RuleSuggestion`s the user has dismissed so they don't reappear on
/// every "Suggest rules" run. Keyed by a stable fingerprint of the suggestion's conditions
/// and outcome — same condition shape ⇒ same fingerprint ⇒ stays dismissed across launches.
@Observable
@MainActor
public final class SuggestionDismissalStore {
    private static let storageKey = "File13.dismissedSuggestions.v1"

    public private(set) var fingerprints: Set<String> = []
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = SharedDefaults.suite) {
        self.defaults = defaults
        if let arr = defaults.array(forKey: Self.storageKey) as? [String] {
            fingerprints = Set(arr)
        }
    }

    public func isDismissed(_ suggestion: RuleSuggestion) -> Bool {
        fingerprints.contains(Self.fingerprint(of: suggestion))
    }

    public func dismiss(_ suggestion: RuleSuggestion) {
        fingerprints.insert(Self.fingerprint(of: suggestion))
        persist()
    }

    public func clear() {
        fingerprints.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(Array(fingerprints), forKey: Self.storageKey)
        CloudKVSync.markDirty(Self.storageKey, defaults: defaults)
    }

    /// Deterministic, lossless fingerprint of a suggestion's match shape.
    public static func fingerprint(of suggestion: RuleSuggestion) -> String {
        var parts: [String] = []
        let c = suggestion.conditions
        if let v = c.fromAddressOrDomain, !v.isEmpty { parts.append("from:\(v.lowercased())") }
        if let v = c.subjectContains,    !v.isEmpty { parts.append("subj:\(v.lowercased())") }
        if let v = c.olderThanDays               { parts.append("old:\(v)") }
        if let v = c.isUnread                    { parts.append("unread:\(v)") }
        if let v = c.category                    { parts.append("cat:\(v.rawValue)") }
        switch suggestion.outcome {
        case .delete:                  parts.append("act:delete")
        case .archive:                 parts.append("act:archive")
        case .moveToFolder(let dest):  parts.append("act:move:\(dest)")
        case .unsubscribe:             parts.append("act:unsubscribe")
        }
        return parts.joined(separator: "|")
    }
}

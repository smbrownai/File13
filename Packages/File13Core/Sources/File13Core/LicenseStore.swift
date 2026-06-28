import Foundation
import Observation
import StoreKit
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Source of truth for "is this user a paying customer."
///
/// The only gate is `tier` — `.pro` or `.free` — sourced from StoreKit's
/// `Transaction.currentEntitlements`. Cached in App Group `UserDefaults`
/// so the CLI and offline launches see the same answer without a
/// StoreKit reachability check.
///
/// `canAddAccount` combines the tier with the current account count into
/// the single decision call sites need ("is the user allowed to add the
/// nth account?"). Free tier allows exactly one mailbox on any number of
/// Apple platforms (Universal Purchase, free).
@Observable
@MainActor
public final class LicenseStore {
    public enum Tier: String, Sendable, Codable {
        case free, pro
    }

    public private(set) var tier: Tier = .free

    /// The paywall predicate used at every "Add account" site (GUI + CLI).
    /// Free tier allows exactly one account; Pro allows any number.
    public func canAddAccount(currentCount: Int) -> Bool {
        tier == .pro || currentCount == 0
    }

    /// User-visible error from the most recent purchase/restore attempt.
    /// `nil` between attempts.
    public private(set) var purchaseError: String?

    /// True while a StoreKit purchase or restore is in flight, so the
    /// paywall sheet can show progress and disable double-taps.
    public private(set) var isWorking: Bool = false

    /// Locale-formatted price string fetched from StoreKit (e.g. "$14.99",
    /// "£49.99", "¥9,800"). `nil` until `fetchDisplayPrice()` resolves.
    /// Views should fall back to "Upgrade to Pro" without a price when nil.
    public private(set) var displayPrice: String?

    // MARK: - Identity

    /// Apple Store Connect product identifier. Single non-consumable IAP,
    /// Universal Purchase enabled at the app level so the same transaction
    /// satisfies both macOS and iOS apps.
    public static let proProductID = "com.shawnbrown.file13.pro"

    // MARK: - Persistence

    private let defaults: UserDefaults
    private enum Keys {
        static let cachedTier = "File13.license.cachedTier"
    }

    /// Long-lived task iterating `Transaction.updates`. Started once at
    /// `bootstrap()` and kept alive for the app's lifetime (the store is
    /// owned by the App's `@State`, so it never deinits before exit — no
    /// explicit cancellation needed).
    private var updatesListener: Task<Void, Never>?

    public init(defaults: UserDefaults = SharedDefaults.suite) {
        self.defaults = defaults
        // Seed from cache so offline launches don't gate a paying user
        // behind a StoreKit reachability check. `bootstrap()` refreshes
        // from the real source of truth once we're online.
        if let raw = defaults.string(forKey: Keys.cachedTier),
           let cached = Tier(rawValue: raw) {
            self.tier = cached
        }
    }

    // MARK: - Bootstrap

    /// One-shot setup called from `File13App` after the scene mounts.
    /// Refreshes the tier from StoreKit and kicks off the long-lived
    /// `Transaction.updates` observation.
    public func bootstrap() async {
        #if DEBUG
        // Skip StoreKit entirely in debug builds — no tier/price round-trip
        // and no `Transaction.updates` listener. Developers shouldn't have
        // to ferry sandbox-Apple-IDs around just to test Pro-gated features,
        // and starting the listener here would make `Transaction.updates`
        // touch StoreKit inside the unit-test host (which has no store
        // configured) and hang the test runner at launch.
        tier = .pro
        defaults.set(Tier.pro.rawValue, forKey: Keys.cachedTier)
        #else
        // Start the transaction listener FIRST — before the tier/price
        // round-trips and therefore before the user can reach the paywall.
        // Apple requires an always-on `Transaction.updates` iteration so we
        // never miss a transaction that arrives outside an explicit
        // `purchase()` call — an Ask-to-Buy approval, a Family Sharing
        // grant, or a purchase interrupted before StoreKit could hand it
        // back. Having it live before any purchase also silences StoreKit's
        // "purchase without listening for transaction updates" warning.
        if updatesListener == nil {
            updatesListener = Task { [weak self] in
                await self?.observeTransactionUpdates()
            }
        }
        await refreshTier()
        await fetchDisplayPrice()
        #endif
    }

    /// Resolve the locale-formatted price from StoreKit and publish it on
    /// `displayPrice`. Best-effort: silent on failure (views just keep
    /// showing "Upgrade to Pro" without the price).
    public func fetchDisplayPrice() async {
        let products = try? await Product.products(for: [Self.proProductID])
        guard let product = products?.first else { return }
        displayPrice = product.displayPrice
    }

    // MARK: - StoreKit

    /// Refresh `tier` from the current set of unrevoked entitlements.
    /// Called on bootstrap and whenever `Transaction.updates` fires.
    private func refreshTier() async {
        for await result in Transaction.currentEntitlements {
            if let txn = try? result.payloadValue,
               txn.productID == Self.proProductID,
               txn.revocationDate == nil {
                setTier(.pro)
                return
            }
        }
        setTier(.free)
    }

    private func setTier(_ new: Tier) {
        tier = new
        defaults.set(new.rawValue, forKey: Keys.cachedTier)
    }

    /// Long-lived loop that listens for fresh transactions (purchases on
    /// other devices via Family Sharing, refunds, expiration of revoked
    /// transactions, etc.). Cancelled implicitly when the app terminates.
    private func observeTransactionUpdates() async {
        for await result in Transaction.updates {
            guard let txn = try? result.payloadValue else { continue }
            await txn.finish()
            await refreshTier()
        }
    }

    // MARK: - Purchase / restore

    public func purchase() async {
        purchaseError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let products = try await Product.products(for: [Self.proProductID])
            guard let product = products.first else {
                purchaseError = "Couldn't find the File13 Pro product in the store. Try again in a moment."
                return
            }
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if let txn = try? verification.payloadValue {
                    await txn.finish()
                    await refreshTier()
                } else {
                    purchaseError = "The purchase didn't pass App Store verification. Try again or contact support."
                }
            case .userCancelled:
                return // silent
            case .pending:
                purchaseError = "Purchase is pending approval (e.g. Ask to Buy). You'll get Pro once it's approved."
            @unknown default:
                purchaseError = "Unexpected purchase result. Try again."
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    public func restore() async {
        purchaseError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppStore.sync()
            await refreshTier()
            if tier == .free {
                purchaseError = "No File13 Pro purchase was found on this Apple ID. If you bought on a different account, sign in with that one in System Settings → Apple ID."
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    #if DEBUG
    public func _debugSetTier(_ tier: Tier) {
        setTier(tier)
    }
    #endif
}

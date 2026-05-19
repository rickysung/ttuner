import Foundation
import StoreKit
import Observation

/// Single source of truth for whether the user has unlocked Pro.
/// Exposed as `ProStore.shared` to match the rest of this codebase's
/// long-lived service objects (`TunerPIPController.shared`,
/// `ReferenceTone.shared`). The instance hangs onto a transaction
/// listener for the lifetime of the app so a refund mid-session
/// downgrades the user immediately.
///
/// All mutations of observable state are hopped to `MainActor` so
/// SwiftUI views read consistent values; the StoreKit-facing async
/// calls themselves run wherever Swift puts them.
@Observable
final class ProStore {
    static let shared = ProStore()

    static let productID = "com.ttuner.app.pro"

    /// Authoritative "is Pro" flag. Anything gating a Pro feature
    /// reads this. Mutated only by `refreshEntitlement()` and the
    /// purchase / restore paths.
    private(set) var isPro: Bool = false

    /// The Pro product as loaded from App Store Connect. `nil` until
    /// the network call returns (or if the device is offline). The
    /// paywall shows a generic label in that state.
    private(set) var product: Product? = nil

    /// True while a purchase or restore is in flight — the paywall
    /// disables its buttons and shows a spinner.
    private(set) var isPurchasing: Bool = false

    /// Surfaced to the paywall as a red error line. Cleared on the
    /// next attempt.
    private(set) var purchaseError: String? = nil

    @ObservationIgnored private var listenerTask: Task<Void, Never>?

    private init() {
        // Transaction.updates fires for renewals, refunds, and
        // promoted-purchase completions. Keep listening forever so
        // a refund mid-session immediately downgrades the user.
        listenerTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    deinit {
        listenerTask?.cancel()
    }

    /// Reload the product metadata from the App Store and re-derive
    /// `isPro` from current entitlements. Safe to call repeatedly —
    /// the paywall calls this when it first appears so the price is
    /// fresh even if the launch fetch failed.
    func refresh() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            await MainActor.run { self.product = products.first }
        } catch {
            // Network or App Store unreachable. Keep last-known
            // product so the paywall still shows something.
        }
        await refreshEntitlement()
    }

    /// Walk every current entitlement looking for our Pro product.
    /// A revoked transaction (refund) leaves `revocationDate` set,
    /// which downgrades the user back to free.
    func refreshEntitlement() async {
        let entitled = await Self.computeEntitlement()
        await MainActor.run { self.isPro = entitled }
    }

    /// Pulled out so the iteration doesn't capture a mutable local
    /// across a concurrent boundary (a Swift 6 error in strict mode).
    private static func computeEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            if t.productID == Self.productID, t.revocationDate == nil {
                return true
            }
        }
        return false
    }

    /// Kick off the App Store purchase sheet. Resolves silently on
    /// `userCancelled` — the paywall stays open so the user can try
    /// again or close it themselves.
    func purchase() async {
        guard let product else { return }
        await MainActor.run {
            self.isPurchasing = true
            self.purchaseError = nil
        }
        defer { Task { @MainActor in self.isPurchasing = false } }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await MainActor.run { self.isPro = true }
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            let message = error.localizedDescription
            await MainActor.run { self.purchaseError = message }
        }
    }

    /// "Restore Purchases" handler. Forces a sync with the App Store
    /// — needed if the user reinstalled the app or switched devices
    /// and the local receipt cache is empty.
    func restore() async {
        await MainActor.run {
            self.isPurchasing = true
            self.purchaseError = nil
        }
        defer { Task { @MainActor in self.isPurchasing = false } }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
        } catch {
            let message = error.localizedDescription
            await MainActor.run { self.purchaseError = message }
        }
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result else { continue }
            await transaction.finish()
            await refreshEntitlement()
        }
    }
}

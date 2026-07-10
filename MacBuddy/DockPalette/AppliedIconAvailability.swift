import Observation

/// Main-actor UI projection of the generation-indexed store. A read failure
/// retains the last known value so a transient filesystem error cannot hide a
/// Restore Originals action that was already known to be available.
@MainActor
@Observable
final class AppliedIconAvailability {
    private(set) var hasDurableRecords = false

    @ObservationIgnored private let store: AppliedIconStore

    init(store: AppliedIconStore = .shared) {
        self.store = store
    }

    func refresh() async {
        guard let hasRestorableState = try? await store.hasRestorableState() else { return }
        hasDurableRecords = hasRestorableState
    }
}

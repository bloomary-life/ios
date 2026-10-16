import Foundation
import Combine

@MainActor
final class SyncSettingsStore: ObservableObject {
    private let key: String

    /// When true, draft sync is disabled to help reduce mobile data usage.
    /// Only available to Pro users.
    @Published var isDataReductionEnabled: Bool

    init(key: String = "bloomary_reduce_data") {
        self.key = key
        self.isDataReductionEnabled = UserDefaults.standard.bool(forKey: key)
    }

    func save() {
        UserDefaults.standard.set(isDataReductionEnabled, forKey: key)
    }
}

import Foundation

final class MenuBarIconStore {
    private enum Keys {
        static let hiddenIconIDs = "menuBarHiddenIconIDs"
        static let hiddenItemsRevealed = "menuBarHiddenItemsRevealed"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hiddenIconIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.hiddenIconIDs) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Keys.hiddenIconIDs) }
    }

    var hiddenItemsRevealed: Bool {
        get {
            if defaults.object(forKey: Keys.hiddenItemsRevealed) == nil {
                return hiddenIconIDs.isEmpty
            }
            return defaults.bool(forKey: Keys.hiddenItemsRevealed)
        }
        set { defaults.set(newValue, forKey: Keys.hiddenItemsRevealed) }
    }

    func setHidden(_ isHidden: Bool, for iconID: String) {
        var ids = hiddenIconIDs
        if isHidden {
            ids.insert(iconID)
        } else {
            ids.remove(iconID)
        }
        hiddenIconIDs = ids
    }
}

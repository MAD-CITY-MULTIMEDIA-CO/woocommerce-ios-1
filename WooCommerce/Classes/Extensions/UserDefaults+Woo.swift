import Foundation



// MARK: - WooCommerce UserDefaults Keys
//
extension UserDefaults {
    enum Key: String {
        case defaultCredentialsType
        case defaultAccountID
        case defaultUsername
        case defaultSiteAddress
        case defaultStoreID
        case defaultStoreName
        case defaultStoreCurrencySettings
        case defaultAnonymousID
        case defaultRoles
        case deviceID
        case deviceToken
        case errorLoginSiteAddress
        case hasFinishedOnboarding
        case userOptedInAnalytics
        case userOptedInCrashLogging = "userOptedInCrashlytics"
        case versionOfLastRun
        case analyticsUsername
        case notificationsLastSeenTime
        case notificationsMarkAsReadCount
        case completedAllStoreOnboardingTasks
    }
}

extension UserDefaults {
    /// User defaults instance ready to be shared between extensions of the same group.
    ///
    static let group = UserDefaults(suiteName: WooConstants.sharedUserDefaultsSuiteName)
}


// MARK: - Convenience Methods
//
extension UserDefaults {

    /// Returns the Object (if any) associated with the specified Key.
    ///
    func object<T>(forKey key: Key) -> T? {
        return value(forKey: key.rawValue) as? T
    }

    /// Stores the Key/Value Pair.
    ///
    func set<T>(_ value: T?, forKey key: Key) {
        set(value, forKey: key.rawValue)
    }

    /// Nukes any object associated with the specified Key.
    ///
    func removeObject(forKey key: Key) {
        removeObject(forKey: key.rawValue)
    }

    /// Indicates if there's an entry for the specified Key.
    ///
    func containsObject(forKey key: Key) -> Bool {
        return value(forKey: key.rawValue) != nil
    }

    /// Subscript Accessible via our new Key type!
    ///
    subscript<T>(key: Key) -> T? {
        get {
            return value(forKey: key.rawValue) as? T
        }
        set {
            set(newValue, forKey: key.rawValue)
        }
    }

    /// Subscript: "Type Inference Fallback". To be used whenever the type cannot be automatically inferred!
    ///
    subscript(key: Key) -> Any? {
        get {
            return value(forKey: key.rawValue)
        }
        set {
            set(newValue, forKey: key.rawValue)
        }
    }
}

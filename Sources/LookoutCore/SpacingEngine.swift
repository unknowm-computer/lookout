import Foundation

/// A property-list wrapper preserves both original value types and absent keys.
public struct PreferenceSnapshot: Codable, Equatable, Sendable {
    public let data: Data?
    public init(value: Any?) throws {
        data = try value.map { try PropertyListSerialization.data(fromPropertyList: [$0], format: .binary, options: 0) }
    }
    public func value() throws -> Any? {
        guard let data else { return nil }
        return (try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any])?.first
    }
}

public struct SpacingValues: Codable, Equatable, Sendable {
    public let spacing: PreferenceSnapshot
    public let padding: PreferenceSnapshot
    public init(spacing: PreferenceSnapshot, padding: PreferenceSnapshot) {
        self.spacing = spacing; self.padding = padding
    }
    public init(spacing: Int, padding: Int) throws {
        self.spacing = try PreferenceSnapshot(value: spacing)
        self.padding = try PreferenceSnapshot(value: padding)
    }
}

public struct SpacingTransaction: Codable, Sendable {
    public let original: SpacingValues
    public var applied: SpacingValues
    public let domain: String
    public init(original: SpacingValues, applied: SpacingValues) {
        self.original = original; self.applied = applied
        domain = "AnyApplication/CurrentUser/CurrentHost"
    }
}

@MainActor public protocol SpacingPreferences: AnyObject {
    func read() throws -> SpacingValues
    func write(_ values: SpacingValues) throws
}

@MainActor public protocol SpacingPersistence: AnyObject {
    func load() throws -> SpacingTransaction?
    func save(_ transaction: SpacingTransaction?) throws
}

public enum SpacingError: Error, LocalizedError {
    case conflict, storage, invalidRange, rollback
    public var errorDescription: String? {
        switch self {
        case .conflict: "다른 앱에서 간격 설정을 변경했습니다. 현재 값을 확인한 후 복원 여부를 선택하세요."
        case .storage: "간격 설정을 저장하거나 읽어 확인할 수 없습니다."
        case .invalidRange: "간격과 클릭 여백은 4~24 범위에서 선택하세요."
        case .rollback: "부분 변경의 원상 복원을 확인하지 못했습니다. 보관된 원래 설정으로 복원을 다시 시도하세요."
        }
    }
}

@MainActor public final class HostSpacingPreferences: SpacingPreferences {
    private let spacingKey = "NSStatusItemSpacing" as CFString
    private let paddingKey = "NSStatusItemSelectionPadding" as CFString
    public init() {}
    public func read() throws -> SpacingValues {
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else { throw SpacingError.storage }
        return SpacingValues(spacing: try PreferenceSnapshot(value: CFPreferencesCopyValue(spacingKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)),
                      padding: try PreferenceSnapshot(value: CFPreferencesCopyValue(paddingKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)))
    }
    public func write(_ values: SpacingValues) throws {
        let spacing = try values.spacing.value()
        let padding = try values.padding.value()
        CFPreferencesSetValue(spacingKey, spacing as CFPropertyList?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSetValue(paddingKey, padding as CFPropertyList?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost),
              try read() == values else { throw SpacingError.storage }
    }
}

@MainActor public final class SpacingEngine {
    private let preferences: any SpacingPreferences
    private let persistence: any SpacingPersistence
    public private(set) var transaction: SpacingTransaction?
    public init(preferences: any SpacingPreferences, persistence: any SpacingPersistence) throws {
        self.preferences = preferences; self.persistence = persistence
        transaction = try persistence.load()
        if let transaction, transaction.domain != "AnyApplication/CurrentUser/CurrentHost" { throw SpacingError.storage }
    }
    public func current() throws -> SpacingValues { try preferences.read() }
    public func hasConflict() throws -> Bool {
        guard let transaction else { return false }
        return try current() != transaction.applied
    }
    public func apply(spacing: Int, padding: Int) throws {
        guard (4...24).contains(spacing), (4...24).contains(padding) else { throw SpacingError.invalidRange }
        guard try !hasConflict() else { throw SpacingError.conflict }
        let before = try current(), target = try SpacingValues(spacing: spacing, padding: padding)
        let previousTransaction = transaction
        let next = SpacingTransaction(original: transaction?.original ?? before, applied: target)
        // Persist recovery data before the system write, including across unexpected termination.
        try persistence.save(next)
        transaction = next
        do { try preferences.write(target) }
        catch {
            do {
                try preferences.write(before)
                guard try current() == before else { throw SpacingError.rollback }
                try persistence.save(previousTransaction)
                transaction = previousTransaction
            } catch { throw SpacingError.rollback }
            throw error
        }
    }
    public func restore(overridingExternalChange: Bool = false) throws {
        guard let transaction else { return }
        if !overridingExternalChange, try hasConflict() { throw SpacingError.conflict }
        let before = try current()
        do {
            try preferences.write(transaction.original)
            guard try current() == transaction.original else { throw SpacingError.storage }
        } catch {
            do { try preferences.write(before) } catch { throw SpacingError.rollback }
            throw error
        }
        try persistence.save(nil)
        self.transaction = nil
    }
}

import Darwin
import Foundation

enum WindowBootSession {
    /// The kernel's boot UUID survives sleep and process restarts, without wall-clock comparisons.
    static func currentID() -> String? {
        var length = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0,
              length > 1, length <= 128 else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return nil }
        let value = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return UUID(uuidString: value)?.uuidString
    }
}

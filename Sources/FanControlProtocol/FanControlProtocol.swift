import Foundation
import Security

public enum FanControlEndpoint {
    public static let name = "local.lookout.fan-helper"
    public static let plist = name + ".plist"
    public static let leaseSeconds = 15.0
}

@objc public protocol FanControlProtocol {
    func setMode(_ mode: String, reply: @escaping @Sendable (String?) -> Void)
    func heartbeat(reply: @escaping @Sendable (Data?, String?) -> Void)
    func restore(reply: @escaping @Sendable (String?) -> Void)
}

public struct FanControlStatus: Codable, Sendable {
    public let mode: String
    public let message: String?
    public let targets: [Int: Double]
    public init(mode: String, message: String? = nil, targets: [Int: Double] = [:]) {
        self.mode = mode; self.message = message; self.targets = targets
    }
}

/// Pin the peer to the signed executable shipped in this bundle. NSXPC enforces the
/// requirement using the connection's audit identity, avoiding PID-reuse checks.
public enum FanPeerIdentity {
    public static func requirement(for executable: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw IdentityError.invalidSignature }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { throw IdentityError.invalidSignature }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else { throw IdentityError.invalidSignature }
        return text as String
    }
    private enum IdentityError: Error { case invalidSignature }
}

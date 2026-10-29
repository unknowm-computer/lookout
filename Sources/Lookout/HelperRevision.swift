import CryptoKit
import Foundation
import FanControlProtocol
import WindowHelperProtocol

/// App UI/signature changes are not helper updates. Include the launch configuration
/// as well as the validated helper identity; OS approval is checked separately.
enum HelperRevision {
    static func current(_ kind: HelperServiceKind, app: URL = Bundle.main.bundleURL) throws -> String {
        let helper: String
        let plist: String
        switch kind {
        case .fan:
            helper = "Contents/Library/Helpers/LookoutFanHelper"
            plist = "Contents/Library/LaunchDaemons/" + FanControlEndpoint.plist
        case .window:
            helper = "Contents/Library/LoginItems/" + WindowHelperEndpoint.bundleName
            plist = "Contents/Library/LaunchAgents/" + WindowHelperEndpoint.plist
        }
        return fingerprint(requirement: try FanPeerIdentity.requirement(for: app.appendingPathComponent(helper)),
                           launchConfiguration: try Data(contentsOf: app.appendingPathComponent(plist)))
    }
    static func fingerprint(requirement: String, launchConfiguration: Data) -> String {
        var data = Data(requirement.utf8)
        data.append(0)
        data.append(launchConfiguration)
        return "helper-v2:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import LookoutCore
import Testing

@Test func updatesStayInactiveUntilBothPublicSettingsArePresent() throws {
    #expect(try UpdateConfiguration.validate(feedURL: nil, publicKey: nil) == nil)
    #expect(try UpdateConfiguration.validate(feedURL: " \n", publicKey: " ") == nil)
    #expect(throws: UpdateConfigurationError.self) {
        try UpdateConfiguration.validate(feedURL: "https://example.com/appcast.xml", publicKey: nil)
    }
    #expect(throws: UpdateConfigurationError.self) {
        try UpdateConfiguration.validate(feedURL: nil, publicKey: Data(repeating: 1, count: 32).base64EncodedString())
    }
}

@Test func updateFeedsRequireHTTPSAndExcludeCredentialsAndFragments() throws {
    let key = Data(repeating: 1, count: 32).base64EncodedString()
    for feed in ["http://example.com/feed.xml", "file:///tmp/feed.xml", "https:///", "https://user:password@example.com/feed", "https://@example.com/feed", "https://example.com/feed#", "https://example.com/feed#section"] {
        #expect(throws: UpdateConfigurationError.self) {
            try UpdateConfiguration.validate(feedURL: feed, publicKey: key)
        }
    }
    let validated = try UpdateConfiguration.validate(feedURL: " https://example.com/appcast.xml?channel=stable \n", publicKey: "\n\(key) ")
    let configuration = try #require(validated)
    #expect(configuration.feedURL.absoluteString == "https://example.com/appcast.xml?channel=stable")
    #expect(configuration.publicKey == key)
}

@Test func updateKeysRequireBase64EncodedEd25519PublicKeyLength() {
    for key in ["not-a-key", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString()] {
        #expect(throws: UpdateConfigurationError.self) {
            try UpdateConfiguration.validate(feedURL: "https://example.com/appcast.xml", publicKey: key)
        }
    }
}

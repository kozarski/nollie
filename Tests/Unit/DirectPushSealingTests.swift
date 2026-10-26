import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Alerts the gateway sends straight to Apple carry generic words, with the real ones sealed for this
/// install. That only works if the device file gives the gateway the key, and the extension opens it.
@MainActor struct DirectPushSealingTests {
    private let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

    private func credentials() -> PushRelay.Credentials {
        PushRelay.Credentials(installID: "install-1", secret: "relay-secret", payloadKey: key)
    }

    @Test func aDirectRegistrationCarriesTheKeyAndNoRelay() throws {
        #expect(PushRelay.url == nil, "no relay is used")
        let runtime = try ChatFixtures.runtime(named: "push-direct-file")
        let push = PushRegistrar(installID: UUID().uuidString)
        let record = push.deviceRecord(token: "apns-token", runtime: runtime,
                                       sealing: PushRelay.deviceFileFields(credentials(), relay: PushRelay.url))
        #expect(record["payload_key"]?.stringValue == key)
        #expect(record["relay"] == nil)
        #expect(record["apns_token"]?.stringValue == "apns-token")
        #expect(record["connection_id"]?.stringValue == runtime.connection.id.uuidString)
    }

    @Test func aRelayLinkIsAddedOnlyWhenThereIsARelay() throws {
        let fields = PushRelay.deviceFileFields(credentials(), relay: URL(string: "https://relay.example"))
        #expect(fields["payload_key"]?.stringValue == key)
        let relay = try #require(fields["relay"]?.objectValue)
        #expect(relay["url"]?.stringValue == "https://relay.example")
        #expect(relay["install_id"]?.stringValue == "install-1")
    }

    /// Made by the companion's `_direct_alert` with this key and an all-zero nonce, for an approval
    /// whose words are not all ASCII.
    @Test func theExtensionOpensADirectSealedAlert() throws {
        let sealed = """
        AAAAAAAAAAAAAAAAdZ7Bt8FA5p8yivpWd1nluRD0djJY8RJA9v/fo6uaODIrO8SQCJDXYkrhS9eTuwdu3W8kxhoQIGb5lkxFOAk+kNZNEijysCSHtOahvjQe\
        atEYR3vcc/cEEWT0WxW/E/Oc9SUmdUk+iPZwHUQOoVeXag6RcAKGCHTuomdXjg1LVaBEnOLlhkwiCnkIq5I0zvBfA3RvF7vYroP0KEMpTA0HjFtA/gd4jKv9\
        6vbQux4myKVVniGogqaFvAG+M2LXOTVeTpeRMeV59FlGjjyaSCMuznVaarAvvRilIQSZ4Hk2ldkRFg75yP7q0ykZfXUGHrMZEQdpn6Loig5QCE0jKFFh80TF\
        7xM5KxbYTDpqvczklDQ9h5Sd6NANvRzoaW4aiOpDrTAF4xaAqvVwcUQNdn86FGT1r0ap5qkKaHdQ/C2zUXHIfeb+JGPMk/2A
        """
        let alert = try PushRelay.openAlert(sealed, keyBase64: key)
        #expect(alert.title == "Scout · approval needed")
        #expect(alert.body == "Run the café script?")
        #expect(alert.category == "HERMES_APPROVAL")
        #expect(alert.threadID == "s-7")
        #expect(alert.timeSensitive)
        #expect(alert.profile == "career")
        #expect(alert.connectionID == UUID(uuidString: "6F1B3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C"))
        #expect(alert.routing?["request_id"]?.stringValue == "rq-7")
        #expect(alert.routing?["text"]?.stringValue == "Fünf Zeilen 字")
    }

    @Test func anotherInstallsKeyOpensNothing() {
        let other = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(throws: (any Error).self) {
            try PushRelay.openAlert("AAAAAAAAAAAAAAAAdZ7Bt8FA5p8yivpWd1nluRD0djJY8RJA9v/fo6uaODIr", keyBase64: other)
        }
    }
}

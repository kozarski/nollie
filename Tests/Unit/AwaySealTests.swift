import CryptoKit
import Foundation
import Testing
@testable import NollieCore

/// Away from home through iCloud: the two devices' keys and the seal on every record. A record
/// opens only on the device it was sealed for, with the header it was sealed with.
struct AwaySealTests {
    private let mac = AwayKey()
    private let phone = AwayKey()
    private let later = Date(timeIntervalSince1970: 1_800_000_900)

    private func pair() throws -> (mac: AwayChannel, phone: AwayChannel) {
        (try AwayChannel(own: mac, side: .mac, otherPublic: phone.publicKey),
         try AwayChannel(own: phone, side: .phone, otherPublic: mac.publicKey))
    }

    @Test func bothEndsAgreeOnTagsAndKeys() throws {
        let (macEnd, phoneEnd) = try pair()
        #expect(macEnd.macTag == phoneEnd.macTag)
        #expect(macEnd.phoneTag == phoneEnd.phoneTag)
        #expect(macEnd.macTag != macEnd.phoneTag)
        #expect(AwayTag.isValid(macEnd.macTag) && AwayTag.isValid(macEnd.phoneTag))
        // A tag says which role it is for: the same key gives a different tag as a phone.
        #expect(AwayTag.of(mac.publicKey, side: .mac) != AwayTag.of(mac.publicKey, side: .phone))

        let plain = Data("Book the table for Friday".utf8)
        let header = phoneEnd.header(expiresAt: later)
        let box = try phoneEnd.seal(plain, header: header)
        #expect(try macEnd.open(box, header: header) == plain)
        // The words are not in the box.
        #expect(box.range(of: Data("table".utf8)) == nil)

        let back = macEnd.header(expiresAt: later, alert: true)
        #expect(try phoneEnd.open(try macEnd.seal(Data("Done".utf8), header: back), header: back) == Data("Done".utf8))
    }

    @Test func aKeyKeptInTheKeychainComesBackTheSame() throws {
        let raw = mac.raw
        #expect(raw.count == 32)
        let again = try #require(AwayKey(raw: raw))
        #expect(again.publicKey == mac.publicKey)
        #expect(AwayKey(raw: Data(repeating: 1, count: 31)) == nil)
        #expect(AwayKey.validPublic(phone.publicKey))
        #expect(!AwayKey.validPublic(Data(repeating: 1, count: 33)))
    }

    @Test func aChangedHeaderNeverOpens() throws {
        let (macEnd, phoneEnd) = try pair()
        let header = phoneEnd.header(expiresAt: later)
        let box = try phoneEnd.seal(Data("Stop".utf8), header: header)

        var longer = header; longer.expiresAt = later.addingTimeInterval(3600)
        var loud = header; loud.alert = true
        var renamed = header; renamed.id = AwayHeader.newID()
        for changed in [longer, loud, renamed] {
            #expect(throws: AwayChannel.Failure.unopened) { try macEnd.open(box, header: changed) }
        }
        // Milliseconds a store adds or drops don't matter; whole seconds do.
        var rounded = header; rounded.expiresAt = later.addingTimeInterval(0.4)
        #expect(try macEnd.open(box, header: rounded) == Data("Stop".utf8))
    }

    @Test func aDamagedOrShortBoxNeverOpens() throws {
        let (macEnd, phoneEnd) = try pair()
        let header = phoneEnd.header(expiresAt: later)
        let box = try phoneEnd.seal(Data("Hello".utf8), header: header)
        for index in [0, 12, box.count / 2, box.count - 1] {
            var flipped = box
            flipped[index] ^= 0x01
            #expect(throws: AwayChannel.Failure.unopened) { try macEnd.open(flipped, header: header) }
        }
        #expect(throws: AwayChannel.Failure.malformed) { try macEnd.open(box.prefix(20), header: header) }
        #expect(throws: AwayChannel.Failure.malformed) { try macEnd.open(Data(), header: header) }
    }

    @Test func aRecordCannotBeTurnedBackOrSentToAnotherDevice() throws {
        let (macEnd, phoneEnd) = try pair()
        let header = phoneEnd.header(expiresAt: later)
        let box = try phoneEnd.seal(Data("Send it".utf8), header: header)
        // The phone can't open its own record as if the Mac had written it.
        #expect(throws: AwayChannel.Failure.notForUs) { try phoneEnd.open(box, header: header) }
        // Swapping the addresses doesn't help: each direction has its own key.
        let swapped = AwayHeader(id: header.id, from: header.to, to: header.from, expiresAt: header.expiresAt, alert: false)
        #expect(throws: AwayChannel.Failure.unopened) { try phoneEnd.open(box, header: swapped) }

        // Another phone linked to the same Mac can't read it, and can't write as this phone.
        let stranger = AwayKey()
        let otherPhone = try AwayChannel(own: stranger, side: .phone, otherPublic: mac.publicKey)
        let otherAtMac = try AwayChannel(own: mac, side: .mac, otherPublic: stranger.publicKey)
        #expect(throws: AwayChannel.Failure.notForUs) { try otherAtMac.open(box, header: header) }
        let forged = AwayHeader(id: AwayHeader.newID(), from: phoneEnd.phoneTag, to: phoneEnd.macTag, expiresAt: later, alert: false)
        #expect(throws: AwayChannel.Failure.notForUs) { try otherPhone.seal(Data("x".utf8), header: forged) }
        // A box sealed by the other phone under this phone's address doesn't open either.
        let theirs = otherPhone.header(expiresAt: later)
        let theirBox = try otherPhone.seal(Data("x".utf8), header: theirs)
        var dressed = theirs; dressed.from = phoneEnd.phoneTag
        #expect(throws: AwayChannel.Failure.unopened) { try macEnd.open(theirBox, header: dressed) }
    }

    @Test func badKeysAndBadHeadersAreRefused() throws {
        #expect(throws: AwayChannel.Failure.badKey) { try AwayChannel(own: mac, side: .mac, otherPublic: Data(repeating: 2, count: 31)) }
        // The all-zero point gives an all-zero secret: refused rather than used.
        #expect(throws: (any Error).self) { try AwayChannel(own: mac, side: .mac, otherPublic: Data(repeating: 0, count: 32)) }
        let (_, phoneEnd) = try pair()
        var bad = phoneEnd.header(expiresAt: later)
        bad.id = "aw1_xyz"
        #expect(throws: AwayChannel.Failure.notForUs) { try phoneEnd.seal(Data(), header: bad) }
        #expect(AwayHeader.isValidID(AwayHeader.newID()))
        #expect(AwayHeader.newID() != AwayHeader.newID())
        #expect(!AwayHeader.isValidID("aw1_" + String(repeating: "A", count: 64)))
    }

    @Test func publicKeysTravelAsBase64URL() throws {
        let text = AwayBase64URL.encode(phone.publicKey)
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        #expect(AwayBase64URL.decode(text) == phone.publicKey)
        #expect(AwayBase64URL.decode("not base64!") == nil)
    }
}

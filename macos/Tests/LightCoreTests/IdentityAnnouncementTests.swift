import Foundation
import Testing
@testable import LightCore

struct IdentityAnnouncementTests {
    private let identifier = UUID(uuidString: syntheticAddress)!
    private let announcement = bytes("ffcc0de402000000000105a4f1ff05ff")

    @Test func extractsCandidateFromCapturedAirEnvelope() throws {
        let candidate = try #require(IdentityAnnouncement.candidate(from: announcement, identifier: identifier))
        #expect(candidate.identifier == identifier)
        #expect(candidate.mac == syntheticMAC)
    }

    @Test func announcementRemainsInvalidAsANormalReply() {
        #expect(throws: (any Error).self) { try LightFrame.decode(announcement) }
    }

    @Test func rejectsDifferentEnvelopeAndDeviceType() {
        for index in [0, 1, 2, 3, 10, 11, 12, 13, 14, 15] {
            var corrupt = announcement
            corrupt[index] ^= 1
            #expect(IdentityAnnouncement.candidate(from: corrupt, identifier: identifier) == nil)
        }
        for length in 0..<announcement.count {
            #expect(IdentityAnnouncement.candidate(from: announcement.prefix(length), identifier: identifier) == nil)
        }
        #expect(IdentityAnnouncement.candidate(from: announcement + Data([0]), identifier: identifier) == nil)
    }

    @Test func rejectsPlaceholderAndBroadcastIdentities() {
        for byte: UInt8 in [0, 0xff] {
            var packet = announcement
            packet.replaceSubrange(4..<10, with: repeatElement(byte, count: 6))
            #expect(IdentityAnnouncement.candidate(from: packet, identifier: identifier) == nil)
        }
    }

    @Test func normalRepliesAreNotIdentityAnnouncements() throws {
        let reply = try LightFrame.encode(mac: syntheticMAC, command: 0xa1, kind: 2, sequence: 0xffff, payload: [1])
        #expect(IdentityAnnouncement.candidate(from: reply, identifier: identifier) == nil)
    }
}

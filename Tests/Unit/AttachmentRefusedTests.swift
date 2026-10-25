import Foundation
import Testing
@testable import NollieCore

/// When the gateway will not take an attachment. A missing tool on its side is explained in
/// plain words (testers thought attachments were broken when it only lacked poppler-utils);
/// everything else is quoted as the gateway said it.
@Suite struct AttachmentRefusedTests {
    private func refusal(_ message: String) -> RPCError { RPCError(code: -32000, message: message) }

    @Test func aMissingPDFReaderIsExplained() {
        let said = "pdftoppm is not installed (the poppler-utils package is required)"
        let note = ChatSession.attachmentFailure(name: "invoice.pdf", kind: .pdf, error: refusal(said))
        #expect(note.hasPrefix("Attachment invoice.pdf was not taken"))
        #expect(note.contains("reads PDFs") && note.contains("poppler-utils"))
        #expect(note.contains("Pictures and text files"))
        #expect(note.hasSuffix("The gateway said: \(said)"))
    }

    @Test func aMissingToolForOtherKindsIsExplainedToo() {
        let note = ChatSession.attachmentFailure(name: "take.mov", kind: .video, error: refusal("ffmpeg: command not found"))
        #expect(note.hasPrefix("Attachment take.mov was not taken") && note.contains("kind of file"))
    }

    @Test func anyOtherRefusalIsQuoted() {
        let note = ChatSession.attachmentFailure(name: "huge.pdf", kind: .pdf, error: refusal("file too large (max 20 MB)"))
        #expect(note == "Attachment huge.pdf failed: file too large (max 20 MB)")
    }
}

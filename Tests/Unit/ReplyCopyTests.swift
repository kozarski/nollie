#if os(macOS)
import Testing
@testable import Nollie

/// Copy on a reply puts the message on the pasteboard exactly as the bot wrote it.
struct ReplyCopyTests {
    @Test(arguments: [
        "\n## Result\n\n- **1.9 GB** back\n- `keep 4` set\n\n```sh\nlogrotate -f /etc/logrotate.conf\n```\n  ",
        "Before and after:\nMEDIA:/home/bot/charts/space.png\nAll good.",
        "", "  ", "Naïve 🙂🏽\n日本語\t", "one\r\ntwo\n",
    ])
    func copiedTextIsTheOriginal(reply: String) {
        #expect(TranscriptMedia.copyText(reply) == reply)
    }
}
#endif

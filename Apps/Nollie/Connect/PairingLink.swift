import Foundation
import NollieCore

/// A pairing code that arrived as a link: the iPhone's Camera opening the Mac's code, a tap on one, or the
/// nollie.app/pair page handing it over.
/// A code that can't be used (run out, already spent, cut short when copied) still says why, so the
/// person never lands back on the app with nothing happening.
enum PairingLink {
    case link(NollieLinkOffer)
    case invitation(DevicePairingInvitation)
    case unusable(String)

    /// What a link holds, or nil when it isn't a pairing code at all (a chat link, say).
    static func read(_ url: URL, now: Date = Date()) -> PairingLink? {
        let raw = url.absoluteString
        // The Mac's https link, or the same code handed over by the nollie.app/pair page's Open Nollie.
        if let link = NollieLinkOffer.linkForm(raw) {
            do throws(NollieLinkError) {
                return .link(try NollieLinkOffer.parse(link, now: now))
            } catch {
                return .unusable(error.localizedDescription)
            }
        }
        if NollieLinkOffer.isAppLink(url) { return .unusable(NollieLinkError.invalidOffer.localizedDescription) }
        guard AppIdentity.acceptsURLScheme(url.scheme), url.host == "pair" else { return nil }
        do {
            return .invitation(try DevicePairingInvitation.parse(raw, now: now))
        } catch let error as DevicePairingError {
            return .unusable(error.localizedDescription)
        } catch {
            return .unusable(DevicePairingError.invalidInvitation.localizedDescription)
        }
    }
}

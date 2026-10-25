import Foundation
import SwiftUI

private struct TranscriptDisclosureScopeKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var transcriptDisclosureScope: String {
        get { self[TranscriptDisclosureScopeKey.self] }
        set { self[TranscriptDisclosureScopeKey.self] = newValue }
    }
}

/// A disclosure keeps its header where it was tapped, regardless of how tall its body becomes.
struct DisclosureScrollAnchor: Equatable {
    let id: String
    let top: CGFloat

    func offset(current: CGFloat, headerTop: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, current + headerTop - top))
    }
}

struct TranscriptDisclosureEvent {
    let id: String
    let top: CGFloat
    let began: Bool
    let scope: String

    init?(notification: Notification) {
        guard let id = notification.userInfo?["id"] as? String,
              let top = notification.userInfo?["top"] as? CGFloat, top.isFinite else { return nil }
        self.id = id
        self.top = top
        began = notification.userInfo?["began"] as? Bool ?? false
        scope = notification.userInfo?["scope"] as? String ?? ""
    }

    static func post(id: String?, top: CGFloat, began: Bool, scope: String) {
        guard let id, top.isFinite else { return }
        NotificationCenter.default.post(name: .hermesRevealRow, object: nil,
                                        userInfo: ["id": id, "top": top, "began": began, "scope": scope])
    }
}

/// A disclosure's header kept still while its body grows: it tells the thread where the header is
/// from the moment the disclosure is tapped until a short while after.
struct DisclosureHold: DynamicProperty {
    @State private var holding = false
    @State private var place = CGRect.zero
    @Environment(\.transcriptDisclosureScope) private var scope

    /// The disclosure was tapped: the thread starts holding its header.
    func begin(id: String?) {
        TranscriptDisclosureEvent.post(id: id, top: place.minY, began: true, scope: scope)
        holding = true
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            holding = false
        }
    }

    /// The header moved; while holding, the thread is told.
    func moved(to frame: CGRect, id: String?) {
        place = frame
        if holding { TranscriptDisclosureEvent.post(id: id, top: frame.minY, began: false, scope: scope) }
    }
}

extension View {
    /// Reports this view's place on screen to `hold` as it changes.
    func holdingHeader(_ hold: DisclosureHold, id: String?) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _, frame in hold.moved(to: frame, id: id) }
    }
}

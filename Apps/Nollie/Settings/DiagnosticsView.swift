import NollieCore
import SwiftUI

/// Settings › About › Diagnostics: a file with what Nollie did today, to share when something went
/// wrong. It is made when the page opens, so Share has something to hand over.
struct DiagnosticsView: View {
    /// Where making the file has got to.
    private enum Making { case working, ready(URL), failed }

    @Environment(AppModel.self) private var model
    @State private var making = Making.working

    var body: some View {
        SettingsPage("diagnostics.page") {
            PageHero(symbol: "stethoscope", title: "Diagnostics", tint: Ink.text2, id: "diagnostics.hero")
            PageNote("A file with what Nollie did today, to share if something went wrong. Private details are left out.")
            switch making {
            case .ready(let file):
                ShareLink(item: file) { PageActionLabel("Share diagnostics", symbol: "square.and.arrow.up") }
                    .pageAction()
                    .testID("diagnostics.share")
            case .failed:
                PageNote("Nollie couldn't make the file. Try again in a moment.", id: "diagnostics.failed")
            case .working:
                ProgressView("Getting it ready")
                    .frame(maxWidth: .infinity)
                    .testID("diagnostics.preparing")
            }
        }
        .untitledPage()
        .task { await makeFile() }
    }

    private func makeFile() async {
        do {
            making = .ready(try await DiagnosticsReport.makeFile(gatewayConnected: model.runtime != nil))
        } catch {
            NollieLog.app.error("Diagnostics file failed", detail: "\(error)")
            making = .failed
        }
    }
}

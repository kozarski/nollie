import SwiftUI

/// The notices for the open-source parts Nollie installs, downloads or ships with. Kept in step with
/// LICENSE and Docs/legal/notices.md (a test checks the Cua and Sparkle texts against LICENSE).
struct AcknowledgementsView: View {
    struct Notice: Identifiable {
        var name: String
        var detail: String
        var licence: String
        /// A plain symbol for its row; never the project's own logo.
        var symbol = "doc.text"
        var id: String { name }
    }

    /// Cua's Hermes plugin, which turning on a helper's own computer installs into its Hermes.
    static let cuaPlugin = """
    MIT License

    Copyright (c) 2026 Cua AI, Inc.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """


    /// Sparkle's own notice, which updates the Direct Mac edition. Its parts from other authors are in
    /// full in LICENSE and in the app's Notices folder.
    static let sparkleMIT = """
    Copyright (c) 2006-2013 Andy Matuschak.
    Copyright (c) 2009-2013 Elgato Systems GmbH.
    Copyright (c) 2011-2014 Kornel Lesiński.
    Copyright (c) 2015-2017 Mayur Pawashe.
    Copyright (c) 2014 C.W. Betts.
    Copyright (c) 2014 Petroules Corporation.
    Copyright (c) 2014 Big Nerd Ranch.
    All rights reserved.

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in
    the Software without restriction, including without limitation the rights to
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
    the Software, and to permit persons to whom the Software is furnished to do so,
    subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
    FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
    COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
    IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    static let sparkle = sparkleMIT + "\n\n"
        + String(localized: "A few parts of Sparkle carry notices of their own. They are in full in the Notices folder inside Nollie on the Mac.")

    /// Names, licence texts and licence names stay as their authors wrote them; only Nollie's own words are localized.
    static let notices: [Notice] = [
        Notice(name: "Hermes Agent", detail: String(localized: "By Nous Research. Downloaded during setup. Not affiliated."),
               licence: "MIT License. Copyright (c) 2025 Nous Research.", symbol: "sparkles"),
        Notice(name: "uv", detail: String(localized: "By Astral. Downloaded during setup."), licence: "MIT or Apache-2.0.", symbol: "shippingbox.fill"),
        Notice(name: "Python", detail: String(localized: "python-build-standalone. Downloaded during setup."),
               licence: String(localized: "PSF-2.0 and the licences it bundles."),
               symbol: "chevron.left.forwardslash.chevron.right"),
        Notice(name: "Sparkle", detail: String(localized: "By the Sparkle Project. Updates the Mac app you download from nollie.app."),
               licence: sparkle, symbol: "arrow.triangle.2.circlepath"),
        Notice(name: "hermes-cua-spaces", detail: String(localized: "By Cua AI, Inc. Added to a helper's Hermes when it gets a computer of its own."),
               licence: cuaPlugin, symbol: "desktopcomputer"),
    ]

    var body: some View {
        SettingsPage("acknowledgements.page") {
            PageHero(symbol: "heart.fill", title: "Thanks", line: "Nollie is built on open work by others.",
                     tint: .pink, id: "acknowledgements.hero")
            GlassStack {
                ForEach(Array(Self.notices.enumerated()), id: \.element.id) { index, notice in
                    GlassLink(.verbatim(notice.name), symbol: notice.symbol, id: "acknowledgements.notice.\(index)") {
                        NoticePage(notice: notice)
                    }
                }
            }
        }
        .untitledPage()
    }
}

/// One notice in full: who made it, how Nollie uses it, and its licence word for word.
private struct NoticePage: View {
    var notice: AcknowledgementsView.Notice

    var body: some View {
        SettingsPage("acknowledgements.notice") {
            PageHero(symbol: notice.symbol, title: .verbatim(notice.name), line: .verbatim(notice.detail), tint: .pink, id: "acknowledgements.notice.hero")
            Text(notice.licence)
                .font(.callout.monospaced())
                .foregroundStyle(Ink.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("acknowledgements.licence")
        }
        .untitledPage()
    }
}

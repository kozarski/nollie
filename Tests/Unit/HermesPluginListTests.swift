import Foundation
import Testing
@testable import Nollie

/// Remove Nollie takes its add-ons out of a person's Hermes settings line by line; everything else
/// in the file stays exactly as it was.
@Suite struct HermesPluginListTests {
    let names: Set<String> = ["nollie-workflow", "nollie-crew", "nollie-reader"]

    @Test func blockListsLoseOnlyNolliesNames() {
        let text = "# my settings\nmodel:\n  default: gpt\nplugins:\n  enabled:\n    - nollie-workflow\n    - web  # mine\n    - \"nollie-crew\"\n  disabled:\n  - nollie-reader\n  - old\n  entries:\n    nollie-workflow:\n      enabled: true\nterminal:\n  backend: local\n"
        let expected = "# my settings\nmodel:\n  default: gpt\nplugins:\n  enabled:\n    - web  # mine\n  disabled:\n  - old\n  entries:\n    nollie-workflow:\n      enabled: true\nterminal:\n  backend: local\n"
        #expect(HermesPluginList.removing(names, from: text) == expected)
    }

    @Test func aListThatEmptiesStaysAList() {
        #expect(HermesPluginList.removing(names, from: "plugins:\n  enabled:\n    - nollie-workflow\n") == "plugins:\n  enabled: []\n")
        #expect(HermesPluginList.removing(names, from: "plugins:\n  enabled: [nollie-crew, 'nollie-reader']  # set by Nollie\n")
                == "plugins:\n  enabled: []  # set by Nollie\n")
        #expect(HermesPluginList.removing(names, from: "plugins:\n  enabled: [a, nollie-crew, b]\n") == "plugins:\n  enabled: [a, b]\n")
    }

    @Test func nothingChangesWithoutNolliesNames() {
        #expect(HermesPluginList.removing(names, from: "plugins:\n  enabled:\n    - web\n") == nil)
        #expect(HermesPluginList.removing(names, from: "model: {}\n") == nil)
        // The name elsewhere in the file (a comment, another key) is never touched.
        #expect(HermesPluginList.removing(names, from: "# nollie-workflow\nnotes:\n  - nollie-workflow\nplugins:\n  enabled: [web]\n") == nil)
        // Forms Hermes doesn't write are left for Hermes, which skips a missing add-on.
        #expect(HermesPluginList.removing(names, from: "plugins:\n  enabled: [[nollie-crew]]\n") == nil)
        #expect(HermesPluginList.removing(names, from: "plugins: {enabled: [nollie-crew]}\n") == nil)
    }
}

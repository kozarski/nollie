import Foundation
import Testing
@testable import Nollie
import NollieCore

@Suite struct ToolStepPresentationTests {
    private func step(_ name: String, status: ToolActivity.Status = .done, context: String? = nil, args: String? = nil) -> ToolActivity {
        ToolActivity(id: UUID().uuidString, name: name, context: context, argsText: args, status: status)
    }

    @Test func familiarToolsHaveReadableActionNames() {
        for (name, title) in [("read_file", "Read file"), ("write_file", "Wrote file"),
                              ("apply_patch", "Edited file"), ("search_files", "Searched files"),
                              ("terminal", "Ran command"), ("bash", "Ran command"),
                              ("web_search", "Searched web"), ("web_extract", "Read page"),
                              ("computer_use", "Used computer"), ("mcp__cua__computer_click", "Used computer"),
                              ("mcp__filesystem__read_file", "Read file")] {
            #expect(ToolStepPresentation(step(name)).title == title)
        }
    }

    @Test func unknownToolsKeepTheirOwnNameWithoutTheTransportNamespace() {
        let presentation = ToolStepPresentation(step("mcp__project__checkReleaseStatus"))
        #expect(presentation.title == "Check Release Status")
        #expect(presentation.symbol == "gearshape")
        #expect(ToolStepPresentation(step("custom_action")).title == "Custom action")
        #expect(ToolStepPresentation(step("  ")).title == "Tool")
    }

    @Test func runningAndFailedStepsNeverClaimCompletion() {
        #expect(ToolStepPresentation(step("write_file", status: .running)).title == "Writing file")
        #expect(ToolStepPresentation(step("write_file", status: .failed)).title == "Write file")
        #expect(ToolStepPresentation(step("terminal", status: .failed)).title == "Run command")
        #expect(ToolStepPresentation(step("computer_use", status: .running)).title == "Using computer")
        #expect(ToolStepPresentation.summary([step("terminal"), step("bash", status: .failed)]) == "Commands")
        #expect(ToolStepPresentation.summary([step("read_file", status: .running), step("write_file")]) == "Reading files, wrote files")
    }

    @Test func detailsDecodeEscapesAndPreferTheExactContext() throws {
        let command = "printf \"a\\b\"\nprintf 'café'"
        let data = try JSONSerialization.data(withJSONObject: ["command": command, "path": "/tmp/work"])
        let args = String(decoding: data, as: UTF8.self)
        let activity = step("terminal", args: args)
        #expect(ToolStepPresentation(activity).detail == command)
        #expect(activity.argsText == args)
        let context = "  source/My File.swift\nline 12  "
        #expect(ToolStepPresentation(step("read_file", context: context, args: args)).detail == context)
        #expect(ToolStepPresentation(step("web_search", args: #"{"query":"caf\u00e9 \"opening hours\"","url":"https://example.invalid"}"#)).detail == "café \"opening hours\"")
        #expect(ToolStepPresentation(step("read_file", args: #"{"path":"/tmp/My File.swift"}"#)).detail == "/tmp/My File.swift")
    }

    @Test func malformedAndUnrelatedArgumentsDoNotInventDetails() {
        #expect(ToolStepPresentation(step("custom_tool", args: "not JSON")).detail == nil)
        #expect(ToolStepPresentation(step("custom_tool", args: #"{"count":3,"result":"done"}"#)).detail == nil)
        #expect(ToolStepPresentation(step("web_extract", context: " \n", args: #"{"url":"https://example.invalid/page?a=1&b=2"}"#)).detail == "https://example.invalid/page?a=1&b=2")
        let command = step("terminal", context: "cat /tmp/read_file.txt && echo web_search")
        #expect(ToolStepPresentation(command).title == "Ran command")
        #expect(ToolStepPresentation(command).symbol == "terminal")
    }

    @Test func summaryKeepsFirstUseOrderAndCountsDistinctRemainingCategories() {
        let steps = [step("read_file"), step("terminal"), step("read_file"), step("web_search"), step("computer_use")]
        #expect(ToolStepPresentation.summary(steps) == "Read files, ran commands + 2 more")
        #expect(ToolStepPresentation.summary([step("bash"), step("terminal"), step("read_file")]) == "Ran commands, read files")
        #expect(ToolStepPresentation.summary([]) == "Steps")
    }

    @Test func iconsStayOrderedUniqueAndCompact() {
        let steps = [step("write_file"), step("apply_patch"), step("terminal"), step("web_search"), step("computer_use")]
        #expect(ToolStepPresentation.symbols(steps) == ["square.and.pencil", "terminal", "globe"])
        #expect(ToolStepPresentation.symbols([]).isEmpty)
    }
}

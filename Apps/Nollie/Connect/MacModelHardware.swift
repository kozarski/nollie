import Foundation
#if os(macOS)
import Darwin
#endif

/// Facts about this Mac, never a claim about a remote Hermes computer or a model's memory fit.
struct MacModelHardware: Equatable, Sendable {
    let processor: String
    let totalMemoryBytes: UInt64
    let isAppleSilicon: Bool

    var summary: String {
        let memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: totalMemoryBytes), countStyle: .memory)
        return String(localized: "\(processor) · \(memory) memory", comment: "A processor name and an amount of memory, such as Apple M4 · 16 GB memory")
    }

    static func current() -> Self? {
        #if os(macOS)
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let silicon = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
        return Self(processor: string("machdep.cpu.brand_string") ?? (silicon ? String(localized: "Apple silicon") : String(localized: "Intel Mac")),
                    totalMemoryBytes: ProcessInfo.processInfo.physicalMemory, isAppleSilicon: silicon)
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func string(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1, size < 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    #endif
}

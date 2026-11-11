import Foundation
import NollieCore

struct LocalModelHardware: Decodable, Equatable, Sendable {
    var uma: Bool?
    var vramTotalBytes: UInt64?
    var vramUsableBytes: UInt64?
    var ramTotalBytes: UInt64?
    var ramAvailableBytes: UInt64?
    var gpuName: String?

    var summary: String {
        guard let total = ramTotalBytes, total > 0 else { return String(localized: "Hermes computer memory is not available.") }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .memory)
        return uma == true ? String(localized: "\(memory) shared memory on your Hermes computer", comment: "%@ is an amount of memory, such as 16 GB")
            : String(localized: "\(memory) memory on your Hermes computer", comment: "%@ is an amount of memory, such as 16 GB")
    }
}

struct LocalModelCatalogEntry: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    var displayName: String
    var description: String?
    var recommended: Bool?
    var recommendedReason: String?
    var fits: Bool?
    var spilled: Bool?
    var needsEngine: Bool?
    var modelId: String?
    var downloaded: Bool?
    var downloadedModelId: String?
    var sizeBytes: UInt64?
    var startWindow: Int?
    var nativeContext: Int?
    var fitSummary: String?
    var quantValidated: Bool?

    var downloadLabel: String {
        guard let bytes = sizeBytes, bytes > 0 else { return String(localized: "Download size not available") }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// File size alone omits context, buffers and vision assets. Hermes prices the launch plan.
    var isRecommendedCandidate: Bool {
        recommended == true && fits == true && spilled == false && needsEngine == false
            && modelId?.isEmpty == false && sizeBytes.map { $0 > 0 } == true
            && startWindow.map { $0 > 0 } == true
    }
}

/// Decode status only when an authorized flow already supplied it. The installed Hermes
/// GET /status can adopt legacy model files, so the inspection client intentionally skips it.
struct LocalModelRuntimeStatus: Decodable, Equatable, Sendable {
    var enabled: Bool?
    var runtimeInstalled: Bool?
    var serverRunning: Bool?
    var activeModelId: String?
}

enum LocalModelSetupIssue: Equatable, Sendable {
    case unsupported, signInRequired, unavailable, invalidResponse

    var message: String {
        switch self {
        case .unsupported: String(localized: "This Hermes version does not offer local model setup here.")
        case .signInRequired: String(localized: "Sign in to your Hermes connection to check local models.")
        case .unavailable: String(localized: "Could not check local models. Try again when the connection is ready.")
        case .invalidResponse: String(localized: "Hermes returned incomplete model information. No model was selected.")
        }
    }
}

struct LocalModelSetupSnapshot: Equatable, Sendable {
    var hardware: LocalModelHardware?
    var models: [LocalModelCatalogEntry]
    var hardwareIssue: LocalModelSetupIssue?
    var catalogIssue: LocalModelSetupIssue?
    /// Free space on this Mac, measured by Nollie (Hermes doesn't say). Nil off the Mac.
    var freeDiskBytes: UInt64? = nil

    /// The same catalog with free space measured again, when there is a new reading.
    func measured(free: UInt64?) -> Self {
        guard let free else { return self }
        var copy = self; copy.freeDiskBytes = free; return copy
    }

    var recommended: LocalModelCatalogEntry? {
        guard hardware?.ramTotalBytes.map({ $0 > 0 }) == true, hardwareIssue == nil, catalogIssue == nil else { return nil }
        return models.first(where: \.isRecommendedCandidate)
    }

    var summary: String {
        if let catalogIssue { return catalogIssue.message }
        if let hardwareIssue { return hardwareIssue.message }
        if let model = recommended {
            return String(localized: "\(model.displayName) is Hermes' suggested fit for this computer. Review its \(model.downloadLabel) model download before continuing.",
                          comment: "The first %@ is a model name, the second its download size")
        }
        return String(localized: "Hermes has no automatic recommendation for this computer. You can review models that fit or keep your current setup.")
    }
}

/// Uses only the authenticated hardware and catalog reads. Inspection never changes a provider,
/// installs an engine, downloads weights, starts a server or selects a cloud fallback.
struct LocalModelSetupClient: Sendable {
    private let read: @Sendable (String) async throws -> Data

    init(api: HermesAPI) {
        read = { path in
            let (data, _) = try await api.raw("GET", path, body: nil, authenticated: true)
            return data
        }
    }

    init(read: @escaping @Sendable (String) async throws -> Data) { self.read = read }

    func inspect() async throws -> LocalModelSetupSnapshot {
        try Task.checkCancellation()
        async let hardware: ReadResult<LocalModelHardware> = fetch("/api/local-models/hardware")
        async let catalog: ReadResult<Catalog> = fetch("/api/local-models/catalog")
        let (facts, choices) = try await (hardware, catalog)
        try Task.checkCancellation()
        return LocalModelSetupSnapshot(hardware: facts.value, models: choices.value?.models ?? [],
                                       hardwareIssue: facts.issue, catalogIssue: choices.issue)
    }

    private struct Catalog: Decodable, Sendable { var models: [LocalModelCatalogEntry] }
    private struct ReadResult<Value: Sendable>: Sendable { var value: Value?; var issue: LocalModelSetupIssue? }

    private func fetch<Value: Decodable & Sendable>(_ path: String) async throws -> ReadResult<Value> {
        do {
            let data = try await read(path)
            try Task.checkCancellation()
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return ReadResult(value: try decoder.decode(Value.self, from: data), issue: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let issue: LocalModelSetupIssue
            switch error {
            case HermesAPIError.http(404, _): issue = .unsupported
            case HermesAPIError.unauthorized, HermesAPIError.sessionExpired: issue = .signInRequired
            case HermesAPIError.http(401, _), HermesAPIError.http(403, _): issue = .signInRequired
            case is DecodingError: issue = .invalidResponse
            default: issue = .unavailable
            }
            return ReadResult(value: nil, issue: issue)
        }
    }
}

/// Sizes as a Mac shows them: decimal gigabytes, one decimal place under 100 GB.
enum LocalModelSize {
    static func label(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1e9
        if gigabytes < 1 {
            return Measurement(value: (Double(bytes) / 1e6).rounded(.up), unit: UnitInformationStorage.megabytes)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        return gb(gigabytes, digits: gigabytes < 100 ? 1 : 0)
    }

    /// Whole gigabytes, rounded up: what something needs.
    static func needed(_ bytes: UInt64) -> String { gb((Double(bytes) / 1e9).rounded(.up), digits: 0) }

    /// Whole gigabytes, rounded down: what there is.
    static func available(_ bytes: UInt64) -> String { gb((Double(bytes) / 1e9).rounded(.down), digits: 0) }

    private static func gb(_ value: Double, digits: Int) -> String {
        Measurement(value: value, unit: UnitInformationStorage.gigabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(digits))))
    }
}

/// Free space on this Mac for a model download. A download starts only when the model fits with
/// room to spare: the engine, the server's own files and the rest of the Mac need space too.
enum LocalModelDisk {
    static let minimumHeadroom: UInt64 = 5_000_000_000

    /// The space a download of `size` bytes needs: the model plus 5 GB, or 5% of it for big ones.
    static func needed(for size: UInt64) -> UInt64 { size + max(minimumHeadroom, size / 20) }

    /// A model already on the Mac needs no more space. Unknown free space is not a reason to refuse.
    static func fits(_ entry: LocalModelCatalogEntry, free: UInt64?) -> Bool {
        guard entry.downloaded != true, let free, let size = entry.sizeBytes else { return true }
        return free >= needed(for: size)
    }

    /// "Needs 104 GB. This Mac has 88 GB free.", or nil when it fits.
    static func shortfall(_ entry: LocalModelCatalogEntry, free: UInt64?) -> String? {
        guard !fits(entry, free: free), let free, let size = entry.sizeBytes else { return nil }
        let need = LocalModelSize.needed(needed(for: size)), have = LocalModelSize.available(free)
        return ModelPlace.sentence(
            mac: String(localized: "Needs \(need). This Mac has \(have) free.", comment: "Disk space: what a model download needs, then what this Mac has, such as 104 GB and 88 GB"),
            phone: String(localized: "Needs \(need). Your Mac has \(have) free.", comment: "Disk space: what a model download needs, then what the Mac has, such as 104 GB and 88 GB"))
    }

    /// Space free on the disk that holds Nollie's setup on this Mac, as macOS counts it for things people keep.
    static func freeBytes() -> UInt64? {
        #if os(macOS)
        #if DEBUG
        if let demo = LocalModelDemo.freeDiskBytes { return demo }
        #endif
        let place = URL.applicationSupportDirectory
        guard let values = try? place.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage, free > 0 else { return nil }
        return UInt64(free)
        #else
        return nil
        #endif
    }
}

/// How long a download takes, in words people read at a glance.
enum LocalModelTime {
    /// 100 Mbit/s, until this Mac has measured its own speed on a download.
    static let assumedBytesPerSecond: Double = 12_500_000
    static let speedKey = "nollie.localModel.measuredBytesPerSecond"

    /// The speed the last download on this Mac really reached, kept for the next estimate.
    static func remember(_ bytesPerSecond: Double, in defaults: UserDefaults = .standard) {
        guard bytesPerSecond.isFinite, bytesPerSecond > 100_000 else { return }
        defaults.set(bytesPerSecond, forKey: speedKey)
    }

    static func measured(in defaults: UserDefaults = .standard) -> Double? {
        let value = defaults.double(forKey: speedKey)
        return value > 100_000 ? value : nil
    }

    /// Seconds rounded for reading: whole minutes up to ten, then fives, then tens past an hour.
    static func rounded(_ seconds: Double) -> Int {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes <= 10 { return minutes * 60 }
        if minutes < 60 { return Int((Double(minutes) / 5).rounded()) * 5 * 60 }
        return Int((Double(minutes) / 10).rounded()) * 10 * 60
    }

    /// "25 min", "1 hr, 20 min".
    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(rounded(seconds))) ?? ""
    }

    /// "about 25 min" for a download not started yet.
    static func estimate(bytes: UInt64, bytesPerSecond: Double? = nil) -> String {
        let speed = bytesPerSecond ?? measured() ?? assumedBytesPerSecond
        return String(localized: "about \(duration(Double(bytes) / speed))", comment: "How long a download may take, such as about 25 min")
    }

    /// "About 12 min left", from the job's own measured speed, or nil when it can't be told honestly.
    static func left(_ job: LocalModelJob?, size: UInt64? = nil) -> String? {
        guard let job, job.status == "running", job.phase == "downloading", let total = job.totalBytes, total > job.doneBytes,
              job.doneBytes > 0, let speed = job.bytesPerSec, speed.isFinite, speed > 0,
              let (done, whole) = LocalModelDownload.bytes(job, size: size), whole > done else { return nil }
        let seconds = Double(whole - done) / speed
        if seconds < 50 { return String(localized: "Less than a minute left") }
        return String(localized: "About \(duration(seconds)) left", comment: "Time left in a download, such as About 12 min left")
    }
}

/// Which models the setup offers, from what Hermes says about this Mac.
///
/// Quick start is the model a person can be chatting with soonest: one already on the Mac first;
/// else the model likely to answer fastest (`quickestToAnswer`); else Hermes's recommendation when
/// it is small (10 GB or less); else the largest model of 10 GB or less; else the smallest that fits.
/// Best for this Mac is Hermes's recommendation (its best
/// quality that runs well here), offered beside it when it differs. Every other model that fits
/// waits under More models. A model that needs more free space than the Mac has is never the
/// default and never starts.
struct LocalModelChoices: Equatable {
    static let quickStartLimit: UInt64 = 10_000_000_000
    /// How much bigger than the smallest download a quicker-answering model may be and still lead.
    static let quickerAnswerAllowance: UInt64 = 10_000_000_000
    /// Active parameters, in billions, that count as few: a 35B-A3B answers about as fast as a 3B model.
    static let fewActiveBillions = 10.0

    /// A mixture-of-experts model's active parameters, in billions, from the size its name gives
    /// ("Qwen3.6-35B-A3B" is 3). Nil for a dense model, or a mixture whose name doesn't say.
    static func activeBillions(_ entry: LocalModelCatalogEntry) -> Double? {
        for name in [entry.id, entry.modelId, entry.displayName].compactMap({ $0 }) {
            guard let match = name.range(of: #"\d+(\.\d+)?[bB][-_ ][aA](\d+(\.\d+)?)[bB]"#, options: .regularExpression) else { continue }
            let tag = name[match]
            guard let a = tag.lastIndex(where: { $0 == "a" || $0 == "A" }) else { continue }
            if let active = Double(tag[tag.index(after: a)...].dropLast()) { return active }
        }
        return nil
    }

    /// The catalog carries no speed, so this is a rule of thumb: a reply takes time in proportion to
    /// the parameters each token uses, and a dense 27B read 17,500 tokens of a first chat in 75 seconds
    /// on a Mac Studio. A mixture-of-experts model with few active parameters, that fits memory and
    /// disk and is at most 10 GB bigger than the smallest download, answers much sooner for the wait.
    /// Fewest active parameters first, then the smaller download.
    static func quickestToAnswer(_ ready: [LocalModelCatalogEntry]) -> LocalModelCatalogEntry? {
        let size: (LocalModelCatalogEntry) -> UInt64 = { $0.sizeBytes ?? .max }
        guard let smallest = ready.map(size).min() else { return nil }
        let limit = smallest.addingReportingOverflow(quickerAnswerAllowance)
        let candidates = ready.compactMap { entry -> (LocalModelCatalogEntry, Double)? in
            guard let active = activeBillions(entry), active <= fewActiveBillions,
                  limit.overflow || size(entry) <= limit.partialValue else { return nil }
            return (entry, active)
        }
        return candidates.min { ($0.1, size($0.0)) < ($1.1, size($1.0)) }?.0
    }

    var quickStart: LocalModelCatalogEntry?
    var best: LocalModelCatalogEntry?
    /// When nothing fits the free space: the smallest model, shown with what it needs, never picked.
    var smallestShort: LocalModelCatalogEntry?
    var more: [LocalModelCatalogEntry]
    var freeDisk: UInt64?

    init(_ snapshot: LocalModelSetupSnapshot) {
        freeDisk = snapshot.freeDiskBytes
        let installable = snapshot.models.filter(\.isInstallableCandidate)
        let free = snapshot.freeDiskBytes
        let ready = installable.filter { LocalModelDisk.fits($0, free: free) }
        let recommended = snapshot.recommended
        let size: (LocalModelCatalogEntry) -> UInt64 = { $0.sizeBytes ?? .max }
        let downloaded = ready.filter { $0.downloaded == true }
        let small = ready.filter { size($0) <= Self.quickStartLimit }
        let quick: LocalModelCatalogEntry?
        if let recommended, downloaded.contains(recommended) {
            quick = recommended
        } else if let biggest = downloaded.max(by: { size($0) < size($1) }) {
            quick = biggest
        } else if let quickest = Self.quickestToAnswer(ready) {
            quick = quickest
        } else if let recommended, small.contains(recommended) {
            quick = recommended
        } else {
            quick = small.max(by: { size($0) < size($1) }) ?? ready.min(by: { size($0) < size($1) })
        }
        let better = recommended.flatMap { $0.isInstallableCandidate && $0.id != quick?.id ? $0 : nil }
        quickStart = quick
        best = better
        let short = quick == nil ? installable.filter { $0.id != better?.id }.min(by: { size($0) < size($1) }) : nil
        smallestShort = short
        let shown = Set([quick?.id, better?.id, short?.id].compactMap { $0 })
        more = installable.filter { !shown.contains($0.id) }.sorted { size($0) < size($1) }
    }

    /// Every model on offer, in the order shown.
    var all: [LocalModelCatalogEntry] { [quickStart, smallestShort, best].compactMap { $0 } + more }

    func canStart(_ entry: LocalModelCatalogEntry) -> Bool {
        entry.isInstallableCandidate && LocalModelDisk.fits(entry, free: freeDisk)
    }

    /// The model picked, if it can start, else Quick start.
    func chosen(_ id: String) -> LocalModelCatalogEntry? {
        all.first { $0.id == id && canStart($0) } ?? quickStart
    }

    /// "18.5 GB · about 25 min", or the size alone when it is already here or can't start.
    func detail(_ entry: LocalModelCatalogEntry) -> String {
        let size = entry.sizeBytes.map(LocalModelSize.label) ?? String(localized: "Download size not available")
        if entry.downloaded == true { return String(localized: "\(size) · Downloaded", comment: "A model's size, then that it is already on the Mac") }
        guard canStart(entry), let bytes = entry.sizeBytes else { return size }
        return String(localized: "\(size) · \(LocalModelTime.estimate(bytes: bytes))", comment: "A model's size, then how long it takes to download, such as 18.5 GB · about 25 min")
    }
}

/// Why a download stopped, from Hermes's own error words, and what to say about it.
enum LocalModelFailure: Equatable {
    case network, disk, checksum, other

    init(_ error: String?) {
        let words = (error ?? "").lowercased()
        if words.contains("no space left") || words.contains("errno 28") || words.contains("enospc") || words.contains("disk full") {
            self = .disk
        } else if words.contains("sha256 mismatch") || words.contains("checksum") || words.contains("hash") {
            self = .checksum
        } else if ["download failed from", "urlopen error", "timed out", "network is unreachable", "connection",
                   "nodename nor servname", "name resolution", "ssl", "temporarily unavailable"].contains(where: words.contains) {
            self = .network
        } else {
            self = .other
        }
    }

    var line: String {
        switch self {
        case .network: String(localized: "Couldn't reach the download. Check your internet, then try again.")
        case .disk: ModelPlace.sentence(mac: String(localized: "This Mac ran out of space. Free some up, then try again."),
                                        phone: String(localized: "Your Mac ran out of space. Free some up, then try again."))
        case .checksum: String(localized: "The download didn't check out. Try again for a fresh copy.")
        case .other: String(localized: "Downloaded parts are kept. Try again to carry on.")
        }
    }
}

#if DEBUG
/// The demo copy's stand-ins for this Mac, so pictures show every state against the mock gateway:
/// `-nollie-demo-local-models` offers the download on the demo's connection, `-nollie-demo-free-disk 88`
/// and `-nollie-demo-mac-memory 8` stand in for this Mac's free space and memory, in gigabytes.
enum LocalModelDemo {
    static var isOn: Bool { DemoMode.isOn && ProcessInfo.processInfo.arguments.contains("-nollie-demo-local-models") }
    static let installationID = UUID(uuidString: "6E0C1D2A-9F4B-4C37-8B51-0D3E2A7C9F10")!

    static var freeDiskBytes: UInt64? { number("-nollie-demo-free-disk").map { UInt64($0 * 1e9) } }
    static var memoryBytes: UInt64? { number("-nollie-demo-mac-memory").map { UInt64($0) << 30 } }

    private static func number(_ flag: String) -> Double? {
        guard DemoMode.isOn else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: flag), at + 1 < args.count, let value = Double(args[at + 1]), value > 0 else { return nil }
        return value
    }
}
#endif

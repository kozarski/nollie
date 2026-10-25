import CoreMedia
import Foundation

/// Turns live frames into sample buffers a display layer can show at once. It keeps the format
/// from the latest keyframe and refuses anything that can't follow on from what it has shown: a
/// missed frame, a size change or a frame before the first keyframe. Then it waits for the next
/// keyframe and counts the frames it dropped meanwhile as late.
public struct LiveSampleBuilder {
    public enum Result {
        case sample(CMSampleBuffer)
        /// Dropped until the next keyframe. `justLost` is true on the first frame refused since
        /// the last keyframe, a fresh start included, when the caller should ask for a keyframe.
        case waitingForKeyframe(justLost: Bool)
    }

    public private(set) var formatDescription: CMVideoFormatDescription?
    public private(set) var late = 0
    public private(set) var waiting = true
    private var parameterSets: [Data]?
    private var expected: UInt32?
    private var asked = false

    public init() {}

    public mutating func take(_ video: LiveWire.Video) -> Result {
        if video.keyframe, let sets = video.parameterSets {
            if sets != parameterSets || !matches(video) {
                guard let format = Self.format(sets), Self.dimensions(format) == (video.width, video.height) else {
                    return lose()
                }
                formatDescription = format
                parameterSets = sets
            }
            waiting = false
            asked = false
        } else if waiting || expected != video.sequence || !matches(video) {
            return lose()
        }
        expected = video.sequence &+ 1
        guard let format = formatDescription, let sample = Self.sampleBuffer(video, format: format) else { return lose() }
        return .sample(sample)
    }

    /// The display couldn't decode what it was given: wait for a keyframe again, and ask for one
    /// with the next frame refused.
    public mutating func lost() {
        waiting = true
        asked = false
    }

    /// Asks again with the next frame refused, for a keyframe that never came.
    public mutating func askAgain() { asked = false }

    private mutating func lose() -> Result {
        let justLost = !asked
        asked = true
        waiting = true
        late += 1
        return .waitingForKeyframe(justLost: justLost)
    }

    private func matches(_ video: LiveWire.Video) -> Bool {
        guard let formatDescription else { return false }
        return Self.dimensions(formatDescription) == (video.width, video.height)
    }

    static func dimensions(_ format: CMVideoFormatDescription) -> (Int, Int) {
        let size = CMVideoFormatDescriptionGetDimensions(format)
        return (Int(size.width), Int(size.height))
    }

    /// An HEVC format from a keyframe's parameter sets, with 4-byte NAL lengths.
    public static func format(_ sets: [Data]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty, sets.allSatisfy({ !$0.isEmpty }) else { return nil }
        let joined = sets.reduce(into: [UInt8]()) { $0.append(contentsOf: $1) }
        let sizes = sets.map(\.count)
        var offsets: [Int] = []
        var offset = 0
        for size in sizes {
            offsets.append(offset)
            offset += size
        }
        var format: CMFormatDescription?
        let status = joined.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            let pointers = offsets.map { base + $0 }
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pointerBuffer.baseAddress!, parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                }
            }
        }
        return status == noErr ? format : nil
    }

    /// One sample over a copy of the frame's bytes, untimed and shown as soon as it decodes.
    static func sampleBuffer(_ video: LiveWire.Video, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = video.sample.count
        guard length > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = video.sample.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var sizes = [length]
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            set(dictionary, kCMSampleAttachmentKey_DisplayImmediately, true)
            if !video.keyframe {
                set(dictionary, kCMSampleAttachmentKey_NotSync, true)
                set(dictionary, kCMSampleAttachmentKey_DependsOnOthers, true)
            }
        }
        return sample
    }

    private static func set(_ dictionary: CFMutableDictionary, _ key: CFString, _ value: Bool) {
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(value ? kCFBooleanTrue : kCFBooleanFalse).toOpaque())
    }
}

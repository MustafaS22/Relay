import CoreMedia
import Foundation

public struct VideoSamples {
    private var format: CMVideoFormatDescription?
    public private(set) var config: VideoConfig?
    private var previous: UInt64?

    public init() {}

    public mutating func configure(_ config: VideoConfig) throws {
        guard (2...4096).contains(config.width), (2...4096).contains(config.height),
              (1...1024).contains(config.sps.count), (1...1024).contains(config.pps.count) else {
            throw RelayError.protocolViolation
        }
        guard self.config != config else { return }
        var format: CMVideoFormatDescription?
        let status = config.sps.withUnsafeBytes { sps in
            config.pps.withUnsafeBytes { pps in
                let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else { throw RelayError.video(status) }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == config.width, dimensions.height == config.height else { throw RelayError.protocolViolation }
        self.format = format
        self.config = config
        previous = nil
    }

    public mutating func resetSequence() { previous = nil }

    public mutating func make(_ frame: VideoFrame) throws -> CMSampleBuffer? {
        guard let format else { return nil }
        guard frame.keyframe || previous.map({ $0 &+ 1 == frame.sequence }) == true else {
            previous = nil
            return nil
        }
        let count = frame.bytes.count
        var buffer: CMBlockBuffer?
        let allocation = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &buffer
        )
        guard allocation == noErr, let buffer else { throw RelayError.video(allocation) }
        let copy = frame.bytes.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: count)
        }
        guard copy == noErr else { throw RelayError.video(copy) }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(clamping: frame.timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: buffer, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw RelayError.video(status) }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(item, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !frame.keyframe {
                CFDictionarySetValue(item, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        previous = frame.sequence
        return sample
    }
}

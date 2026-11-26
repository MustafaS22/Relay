import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class DecodePipeline: @unchecked Sendable {
    public enum Output: @unchecked Sendable {
        case image(CMSampleBuffer, UInt64)
        case needsKeyframe
        case failed(String)
    }
    private let queue = DispatchQueue(label: "relay.video.decode", qos: .userInteractive)
    private var samples = VideoSamples()
    private var session: VTDecompressionSession?
    private var outputFormat: CMVideoFormatDescription?
    private var epoch = 0
    private var pending = 0
    private var lastPresented: UInt64?
    private var requestedKeyframe = false
    private let delivery: AsyncStream<Output>.Continuation
    public let output: AsyncStream<Output>

    public init() {
        (output, delivery) = AsyncStream.makeStream(of: Output.self, bufferingPolicy: .bufferingNewest(2))
    }

    public func reset() { queue.async { self.resetOnQueue() } }

    public func close() {
        delivery.finish()
        reset()
    }

    public func configure(_ config: VideoConfig) {
        queue.async {
            guard self.samples.config != config else { return }
            self.resetOnQueue()
            do { try self.samples.configure(config) } catch {
                self.delivery.yield(.failed(error.localizedDescription))
            }
        }
    }

    // Completion acknowledges consumption so the sender can cap TCP buffering.
    public func decode(_ frame: VideoFrame, completion: @escaping @Sendable () -> Void) {
        queue.async {
            do {
                guard self.pending < 3 else {
                    self.requestKeyframe()
                    completion()
                    return
                }
                guard let sample = try self.samples.make(frame) else {
                    self.requestKeyframe()
                    completion()
                    return
                }
                if self.session == nil, let format = sample.formatDescription {
                    #if targetEnvironment(simulator)
                    let specification: CFDictionary? = nil
                    #else
                    let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
                    #endif
                    let status = VTDecompressionSessionCreate(
                        allocator: nil, formatDescription: format, decoderSpecification: specification,
                        imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &self.session
                    )
                    guard status == noErr else { throw RelayError.video(status) }
                }
                guard let session = self.session else { throw RelayError.protocolViolation }
                if frame.keyframe { self.requestedKeyframe = false }
                self.pending += 1
                let epoch = self.epoch
                let status = VTDecompressionSessionDecodeFrame(
                    session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
                ) { status, _, image, time, _ in
                    self.queue.async {
                        defer { completion() }
                        guard self.epoch == epoch else { return }
                        self.pending -= 1
                        guard status == noErr, let image else {
                            self.requestKeyframe()
                            return
                        }
                        guard self.lastPresented.map({ frame.sequence > $0 }) != false else { return }
                        self.lastPresented = frame.sequence
                        self.present(image, time: time, timestamp: frame.timestampMicros)
                    }
                }
                if status != noErr {
                    self.pending -= 1
                    self.requestKeyframe()
                    completion()
                }
            } catch {
                self.delivery.yield(.failed(error.localizedDescription))
                completion()
            }
        }
    }

    private func requestKeyframe() {
        samples.resetSequence()
        guard !requestedKeyframe else { return }
        requestedKeyframe = true
        delivery.yield(.needsKeyframe)
    }

    private func resetOnQueue() {
        epoch += 1
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        outputFormat = nil
        samples = VideoSamples()
        pending = 0
        lastPresented = nil
        requestedKeyframe = false
    }

    private func present(_ image: CVPixelBuffer, time: CMTime, timestamp: UInt64) {
        if outputFormat.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: image) }) ?? true {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &outputFormat)
        }
        guard let outputFormat else { return }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: image, formatDescription: outputFormat,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(item, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        delivery.yield(.image(sample, timestamp))
    }
}

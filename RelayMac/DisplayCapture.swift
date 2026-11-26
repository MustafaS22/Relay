import AppKit
import CoreMedia
import OSLog
import RelayCore
import ScreenCaptureKit
import VideoToolbox

struct EncodedVideo: Sendable {
    let frame: VideoFrame
    let config: VideoConfig?
}

struct CaptureDevice {
    let display: SCDisplay
    let info: DisplayInfo

    @MainActor
    static func catalog() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(id: id, name: screen.localizedName, width: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                               height: mode?.pixelHeight ?? CGDisplayPixelsHigh(id))
        }
    }

    static func open(_ info: DisplayInfo) async throws -> CaptureDevice {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == info.id }) else {
            throw RelayError.message("The selected display is unavailable.")
        }
        return CaptureDevice(display: display, info: info)
    }
}

final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.mustafas22.relay", category: "capture")
    private let queue = DispatchQueue(label: "relay.screen.capture", qos: .userInteractive)
    private let inflight = DispatchSemaphore(value: 2)
    private let delivery: AsyncStream<EncodedVideo>.Continuation
    private let failure: @Sendable (String) -> Void
    private let generation = UUID()
    private let fps: Int
    private let width: Int
    private let height: Int
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private var encoder: VTCompressionSession?
    private var latest: CVPixelBuffer?
    private var lastEncoded = 0.0
    private var forceKeyframe = true
    private var sequence: UInt64 = 0
    private var captured = 0
    private var encoded = 0
    private var dropped = 0
    private var bytes = 0

    init(device: CaptureDevice, quality: Quality, delivery: AsyncStream<EncodedVideo>.Continuation,
         failure: @escaping @Sendable (String) -> Void) throws {
        self.delivery = delivery
        self.failure = failure
        fps = quality.fps
        let dimensions = quality.dimensions(width: device.info.width, height: device.info.height)
        width = dimensions.width
        height = dimensions.height
        super.init()

        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder
        )
        guard status == noErr, let encoder else { throw RelayError.video(status) }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_AverageBitRate: quality.bitrate
        ]
        let configured = VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary)
        guard configured == noErr else { throw RelayError.video(configured) }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(encoder)
        guard prepared == noErr else { throw RelayError.video(prepared) }

        let filter = SCContentFilter(display: device.display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = 3
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = capture
    }

    func start() async throws {
        guard let stream else { throw RelayError.disconnected }
        try await stream.startCapture()
        queue.async { [weak self] in
            guard let self, self.encoder != nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: .milliseconds(500), leeway: .milliseconds(30))
            timer.setEventHandler { [weak self] in
                guard let self, let latest = self.latest else { return }
                if self.forceKeyframe || ProcessInfo.processInfo.systemUptime - self.lastEncoded >= 0.9 {
                    self.encode(latest, time: CMClockGetTime(CMClockGetHostTimeClock()))
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() async {
        let capture = stream
        stream = nil
        delivery.finish()
        await withCheckedContinuation { continuation in
            queue.async {
                self.timer?.cancel()
                self.timer = nil
                self.latest = nil
                if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
                self.encoder = nil
                continuation.resume()
            }
        }
        try? await capture?.stopCapture()
    }

    func keyframe() {
        queue.async { [weak self] in self?.forceKeyframe = true }
    }

    func bitrate(_ value: Int) {
        queue.async { [weak self] in
            guard let self, let encoder = self.encoder else { return }
            let status = VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: value as NSNumber)
            if status != noErr { Self.logger.error("Bitrate update failed: \(status)") }
        }
    }

    func stats() async -> StreamStats {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: StreamStats(captured: self.captured, encoded: self.encoded,
                                                           dropped: self.dropped, bitrate: self.bytes * 8))
                self.captured = 0
                self.encoded = 0
                self.dropped = 0
                self.bytes = 0
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failure("Screen capture stopped. \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachment = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                                as? [[SCStreamFrameInfo: Any]])?.first,
              let value = attachment[.status] as? Int, value == SCFrameStatus.complete.rawValue,
              let pixels = sample.imageBuffer else { return }
        captured += 1
        latest = pixels
        // Stamp with the host clock for cross-device latency estimates and monotonic refresh frames.
        encode(pixels, time: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private func encode(_ pixels: CVPixelBuffer, time: CMTime) {
        guard let encoder else { return }
        guard inflight.wait(timeout: .now()) == .success else { dropped += 1; return }
        let options = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        lastEncoded = ProcessInfo.processInfo.systemUptime
        sequence &+= 1
        let number = sequence
        let micros = UInt64(max(0, time.seconds * 1_000_000))
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: pixels, presentationTimeStamp: time,
            duration: .invalid, frameProperties: options, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self else { return }
            self.queue.async {
                defer { self.inflight.signal() }
                guard self.encoder != nil else { return }
                guard status == noErr else {
                    self.failure(RelayError.video(status).localizedDescription)
                    return
                }
                guard let sample else { self.dropped += 1; return }
                self.publish(sample, sequence: number, micros: micros)
            }
        }
        if status != noErr {
            inflight.signal()
            failure(RelayError.video(status).localizedDescription)
        }
    }

    private func publish(_ sample: CMSampleBuffer, sequence: UInt64, micros: UInt64) {
        guard let block = sample.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard (1...(RelayProtocol.frameLimit - 17)).contains(length) else {
            dropped += 1
            return
        }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard status == noErr else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        var config: VideoConfig?
        if keyframe, let format = sample.formatDescription, let sps = parameter(format, index: 0),
           let pps = parameter(format, index: 1) {
            config = VideoConfig(generation: generation, width: width, height: height, sps: sps, pps: pps)
        }
        let result = delivery.yield(EncodedVideo(
            frame: VideoFrame(sequence: sequence, timestampMicros: micros, keyframe: keyframe, bytes: data),
            config: config
        ))
        if case .dropped = result { dropped += 1 }
        encoded += 1
        bytes += length
    }

    private func parameter(_ format: CMFormatDescription, index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}

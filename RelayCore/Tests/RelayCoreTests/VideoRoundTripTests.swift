import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import RelayCore

final class VideoRoundTripTests: XCTestCase {
    func testHardwareH264AndRecoveryAfterSequenceGap() async throws {
        let (config, frame) = try await encodedFrame()
        var samples = VideoSamples()
        try samples.configure(config)
        XCTAssertNotNil(try samples.make(frame))
        let gap = VideoFrame(sequence: 3, timestampMicros: 200_000, keyframe: false, bytes: frame.bytes)
        XCTAssertNil(try samples.make(gap))
        let followup = VideoFrame(sequence: 4, timestampMicros: 250_000, keyframe: false, bytes: frame.bytes)
        XCTAssertNil(try samples.make(followup))
        let recovery = VideoFrame(sequence: 5, timestampMicros: 300_000, keyframe: true, bytes: frame.bytes)
        XCTAssertNotNil(try samples.make(recovery))

        let decoded = expectation(description: "hardware H.264 decoded an image")
        let pipeline = DecodePipeline()
        let reader = Task {
            for await output in pipeline.output {
                if case .image(let sample, let stamp) = output {
                    XCTAssertEqual(stamp, frame.timestampMicros)
                    XCTAssertEqual(sample.imageBuffer.map(CVPixelBufferGetWidth), 320)
                    XCTAssertEqual(sample.imageBuffer.map(CVPixelBufferGetHeight), 240)
                    decoded.fulfill()
                    return
                }
                if case .failed(let reason) = output {
                    XCTFail(reason)
                    decoded.fulfill()
                    return
                }
            }
        }
        defer { pipeline.close(); reader.cancel() }
        pipeline.configure(config)
        pipeline.decode(frame) {}
        await fulfillment(of: [decoded], timeout: 4)
    }

    private func encodedFrame() async throws -> (VideoConfig, VideoFrame) {
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                            attributes, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(image) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(image, plane) {
                memset(base, plane == 0 ? 125 : 128,
                       CVPixelBufferGetHeightOfPlane(image, plane) * CVPixelBufferGetBytesPerRowOfPlane(image, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])

        var session: VTCompressionSession?
        let hardware = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let create = VTCompressionSessionCreate(allocator: nil, width: 320, height: 240,
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: hardware,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                                refcon: nil, compressionSessionOut: &session)
        guard create == noErr, let session else { throw RelayError.video(create) }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let sample: CMSampleBuffer = try await withCheckedThrowingContinuation { continuation in
            let encode = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: .zero,
                                                          duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                if status == noErr, let sample { continuation.resume(returning: sample) }
                else { continuation.resume(throwing: RelayError.video(status)) }
            }
            if encode != noErr { continuation.resume(throwing: RelayError.video(encode)) }
            else { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
        }
        let format = try XCTUnwrap(sample.formatDescription)
        let block = try XCTUnwrap(sample.dataBuffer)
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        XCTAssertEqual(bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }, noErr)
        func parameter(_ index: Int) throws -> Data {
            var pointer: UnsafePointer<UInt8>?
            var count = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &count,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            XCTAssertEqual(status, noErr)
            return Data(bytes: try XCTUnwrap(pointer), count: count)
        }
        return (try VideoConfig(generation: UUID(), width: 320, height: 240, sps: parameter(0), pps: parameter(1)),
                VideoFrame(sequence: 1, timestampMicros: 100_000, keyframe: true, bytes: bytes))
    }
}

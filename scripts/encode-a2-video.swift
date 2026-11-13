// Encode RGB24 frames from stdin using macOS's native H.264 encoder.
// --timestamps prefixes each frame with a little-endian UInt64 microsecond PTS.
// Compatibility writer APIs keep this development helper usable on macOS 13+.
import Foundation
import AVFoundation
import CoreVideo

struct VideoError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func encode() throws {
    let timestamped = CommandLine.arguments.count == 6 && CommandLine.arguments[5] == "--timestamps"
    guard (CommandLine.arguments.count == 5 || timestamped),
          let width = Int(CommandLine.arguments[2]), let height = Int(CommandLine.arguments[3]),
          let fps = Int32(CommandLine.arguments[4]), width > 0, height > 0,
          width <= 4096, height <= 4096, width % 2 == 0, height % 2 == 0, fps > 0, fps <= 60 else {
        throw VideoError("Usage: encode-a2-video OUTPUT.mp4 WIDTH HEIGHT FPS [--timestamps] < FRAMES")
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    guard !FileManager.default.fileExists(atPath: url.path) else { throw VideoError("Output already exists") }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000,
            AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
    guard writer.canAdd(input) else { throw VideoError("Cannot add H.264 input") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? VideoError("Cannot start writer") }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw VideoError("No pixel buffer pool") }
    let frameBytes = width * height * 3
    var count: Int64 = 0
    var lastTime = CMTime.zero
    while true {
        var presentationTime = CMTime(value: count, timescale: fps)
        if timestamped {
            var header = Data()
            while header.count < 8 {
                guard let data = try FileHandle.standardInput.read(upToCount: 8-header.count), !data.isEmpty else { break }
                header.append(data)
            }
            if header.isEmpty { break }
            guard header.count == 8 else { throw VideoError("Truncated timestamp") }
            var micros: UInt64 = 0
            for i in 0..<8 { micros |= UInt64(header[i]) << (i*8) }
            guard micros <= UInt64(Int64.max) else { throw VideoError("Invalid timestamp") }
            presentationTime = CMTime(value: Int64(micros), timescale: 1_000_000)
            guard count == 0 || presentationTime > lastTime else { throw VideoError("Nonmonotonic timestamp") }
        }
        var frame = Data()
        while frame.count < frameBytes {
            guard let data = try FileHandle.standardInput.read(upToCount: frameBytes - frame.count), !data.isEmpty else { break }
            frame.append(data)
        }
        if frame.isEmpty && !timestamped { break }
        guard frame.count == frameBytes else { throw VideoError("Truncated RGB frame") }
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard input.isReadyForMoreMediaData else { throw writer.error ?? VideoError("Encoder stalled") }
        try autoreleasepool {
            var optional: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &optional) == kCVReturnSuccess,
                  let buffer = optional else { throw VideoError("Cannot allocate pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!
            frame.withUnsafeBytes { (rgb: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                    for x in 0..<width {
                        let p = (y * width + x) * 3
                        row[x] = UInt32(rgb[p + 2]) | UInt32(rgb[p + 1]) << 8 | UInt32(rgb[p]) << 16 | 0xff000000
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? VideoError("Cannot append video frame")
            }
        }
        lastTime = presentationTime
        count += 1
    }
    guard count > 0 else { writer.cancelWriting(); throw VideoError("No video frames") }
    writer.endSession(atSourceTime: lastTime + CMTime(value: 1, timescale: fps))
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    guard finished.wait(timeout: .now() + 30) == .success, writer.status == .completed else {
        throw writer.error ?? VideoError("Cannot finish video")
    }
    print("Recorded \(count) frames; duration \(lastTime.seconds) seconds; timestamped=\(timestamped)")
}

do { try encode() }
catch {
    FileHandle.standardError.write(Data("Video encoding failed: \(error)\n".utf8))
    exit(1)
}

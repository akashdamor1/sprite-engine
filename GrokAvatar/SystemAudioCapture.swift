import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Accelerate

/// Captures system (other apps') audio PCM via ScreenCaptureKit and reports
/// RMS energy plus simple low/mid/high band proxies for lip-sync.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Analysis {
        var rms: Float
        var low: Float
        var mid: Float
        var high: Float
    }

    private var stream: SCStream?
    private let onAnalysis: (Analysis) -> Void
    private let queue = DispatchQueue(label: "grokavatar.system.audio", qos: .userInteractive)

    private var lpState: Float = 0
    private var bpState: Float = 0
    private let lpAlpha: Float = 0.15
    private let bpAlpha: Float = 0.45

    private var loggedUnexpectedFormat = false
    private var samplesFlowingLogged = false

    init(onAnalysis: @escaping (Analysis) -> Void) {
        self.onAnalysis = onAnalysis
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "GrokAvatar", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display for ScreenCaptureKit"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let asbd = asbdPtr.pointee

        var sizeNeeded: Int = 0
        // Probe required AudioBufferList size
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: sizeNeeded)
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }
        // Keep blockBuffer alive for the duration of this call
        withExtendedLifetime(blockBuffer) {
            processABL(ablPtr, asbd: asbd)
        }
    }

    private func processABL(_ ablPtr: UnsafeMutablePointer<AudioBufferList>, asbd: AudioStreamBasicDescription) {
        let list = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard list.count > 0 else { return }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bits = Int(asbd.mBitsPerChannel)
        let channelsFromASBD = Int(asbd.mChannelsPerFrame)
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var mono: [Float] = []

        if isFloat && bits == 32 {
            if isNonInterleaved {
                // One AudioBuffer per channel
                let ch = list.count
                guard ch > 0, let first = list[0].mData else { return }
                let frameCount = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
                guard frameCount > 0 else { return }
                mono = [Float](repeating: 0, count: frameCount)
                if ch == 1 {
                    let src = first.assumingMemoryBound(to: Float.self)
                    for i in 0..<frameCount { mono[i] = src[i] }
                } else {
                    for c in 0..<ch {
                        guard let d = list[c].mData else { continue }
                        let src = d.assumingMemoryBound(to: Float.self)
                        for i in 0..<frameCount {
                            mono[i] += src[i]
                        }
                    }
                    let inv = 1.0 / Float(ch)
                    for i in 0..<frameCount { mono[i] *= inv }
                }
            } else {
                guard let data = list[0].mData else { return }
                let channels = max(1, channelsFromASBD > 0 ? channelsFromASBD : Int(list[0].mNumberChannels))
                let sampleCount = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
                let frameCount = sampleCount / channels
                guard frameCount > 0 else { return }
                let src = data.assumingMemoryBound(to: Float.self)
                mono = [Float](repeating: 0, count: frameCount)
                if channels == 1 {
                    for i in 0..<frameCount { mono[i] = src[i] }
                } else {
                    for i in 0..<frameCount {
                        var sum: Float = 0
                        for c in 0..<channels { sum += src[i * channels + c] }
                        mono[i] = sum / Float(channels)
                    }
                }
            }
        } else if bits == 16 {
            if isNonInterleaved {
                let ch = list.count
                guard ch > 0, let first = list[0].mData else { return }
                let frameCount = Int(list[0].mDataByteSize) / MemoryLayout<Int16>.size
                guard frameCount > 0 else { return }
                mono = [Float](repeating: 0, count: frameCount)
                let scale = 1.0 / Float(Int16.max)
                if ch == 1 {
                    let src = first.assumingMemoryBound(to: Int16.self)
                    for i in 0..<frameCount { mono[i] = Float(src[i]) * scale }
                } else {
                    for c in 0..<ch {
                        guard let d = list[c].mData else { continue }
                        let src = d.assumingMemoryBound(to: Int16.self)
                        for i in 0..<frameCount {
                            mono[i] += Float(src[i]) * scale
                        }
                    }
                    let inv = 1.0 / Float(ch)
                    for i in 0..<frameCount { mono[i] *= inv }
                }
            } else {
                guard let data = list[0].mData else { return }
                let channels = max(1, channelsFromASBD > 0 ? channelsFromASBD : Int(list[0].mNumberChannels))
                let sampleCount = Int(list[0].mDataByteSize) / MemoryLayout<Int16>.size
                let frameCount = sampleCount / channels
                guard frameCount > 0 else { return }
                let src = data.assumingMemoryBound(to: Int16.self)
                let scale = 1.0 / Float(Int16.max)
                mono = [Float](repeating: 0, count: frameCount)
                if channels == 1 {
                    for i in 0..<frameCount { mono[i] = Float(src[i]) * scale }
                } else {
                    for i in 0..<frameCount {
                        var sum: Float = 0
                        for c in 0..<channels { sum += Float(src[i * channels + c]) * scale }
                        mono[i] = sum / Float(channels)
                    }
                }
            }
        } else {
            if !loggedUnexpectedFormat {
                loggedUnexpectedFormat = true
                NSLog("GrokAvatar unexpected audio format: bits=%d float=%d channels=%u nonInterleaved=%d",
                      bits, isFloat ? 1 : 0, asbd.mChannelsPerFrame, isNonInterleaved ? 1 : 0)
            }
            return
        }

        guard !mono.isEmpty else { return }
        analyze(mono: &mono)
        if !samplesFlowingLogged {
            samplesFlowingLogged = true
            NSLog("GrokAvatar SystemAudioCapture: PCM samples flowing")
        }
    }

    private func analyze(mono: inout [Float]) {
        let count = mono.count
        guard count > 0 else { return }

        var rms: Float = 0
        mono.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(count))
        }

        var lowAcc: Float = 0
        var midAcc: Float = 0
        var highAcc: Float = 0
        var lp = lpState
        var bp = bpState

        for i in 0..<count {
            let x = mono[i]
            lp += lpAlpha * (x - lp)
            var midLp = bp
            midLp += bpAlpha * (x - midLp)
            let mid = midLp - lp
            let high = x - midLp
            lowAcc += lp * lp
            midAcc += mid * mid
            highAcc += high * high
            bp = midLp
        }

        lpState = lp
        bpState = bp

        let inv = 1.0 / Float(count)
        onAnalysis(Analysis(
            rms: rms,
            low: sqrt(lowAcc * inv),
            mid: sqrt(midAcc * inv),
            high: sqrt(highAcc * inv)
        ))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("GrokAvatar SystemAudioCapture stopped: %@", error.localizedDescription)
    }
}

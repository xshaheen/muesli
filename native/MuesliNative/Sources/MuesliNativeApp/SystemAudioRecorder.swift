import Atomics
import AVFoundation
import Foundation
import ScreenCaptureKit
import MuesliCore
import os

enum SystemAudioStartupError: LocalizedError, Equatable {
    case timedOut

    var errorDescription: String? {
        "Timed out while starting system audio capture"
    }
}

private final class SystemAudioStartupGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadlineWorkItem: DispatchWorkItem?
    private var isFinished = false
    private var isCancelled = false

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if isCancelled {
            isFinished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        guard !isFinished, self.continuation == nil else {
            lock.unlock()
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return false
        }
        isFinished = true
        self.continuation = nil
        let deadlineWorkItem = self.deadlineWorkItem
        self.deadlineWorkItem = nil
        lock.unlock()

        deadlineWorkItem?.cancel()
        continuation.resume(with: result)
        return true
    }

    func arm(timeout: TimeInterval) {
        let workItem = DispatchWorkItem { [self] in
            resolve(.failure(SystemAudioStartupError.timedOut))
        }
        lock.lock()
        guard !isFinished, continuation != nil else {
            lock.unlock()
            return
        }
        deadlineWorkItem = workItem
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeout,
            execute: workItem
        )
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let deadlineWorkItem = self.deadlineWorkItem
        self.deadlineWorkItem = nil
        if continuation != nil {
            isFinished = true
        }
        lock.unlock()

        deadlineWorkItem?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}

enum SystemAudioStartupDeadline {
    static func wait<Value>(
        timeout: TimeInterval,
        start: @escaping () async throws -> Value,
        onLateSuccess: @escaping (Value) async -> Void,
        onLateFailure: @escaping (Error) async -> Void = { _ in }
    ) async throws -> Value {
        let gate = SystemAudioStartupGate<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                Task {
                    do {
                        let value = try await start()
                        if !gate.resolve(.success(value)) {
                            await onLateSuccess(value)
                        }
                    } catch {
                        if !gate.resolve(.failure(error)) {
                            await onLateFailure(error)
                        }
                    }
                }
                gate.arm(timeout: timeout)
                if Task.isCancelled {
                    gate.cancel()
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }
}

struct SystemAudioCaptureFailureGate {
    private(set) var isActive = false
    private var didReportFailure = false

    mutating func activate() {
        isActive = true
        didReportFailure = false
    }

    mutating func deactivate() {
        isActive = false
    }

    mutating func shouldReportUnexpectedStop() -> Bool {
        guard isActive, !didReportFailure else { return false }
        didReportFailure = true
        return true
    }
}

final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, SystemAudioCapturing, SystemAudioDiagnosticsProviding {
    var onPCMSamples: (([Int16]) -> Void)?
    var onSystemAudioInterruption: (() -> Void)?
    var onSystemAudioFailure: ((Error) -> Void)?
    var onSystemAudioRecovery: (() -> Void)?

    /// Guards `stream` and `startFailed`: `startStream()` assigns from the
    /// startup task while `stop()` and `cleanupFailedStart()` read from the
    /// caller's thread.
    private let streamStateQueue = DispatchQueue(label: "com.muesli.system-audio.stream-state")
    /// The stream currently inside `startCapture()`. Delegate failure can arrive
    /// before that async call returns, so retain its identity and error until the
    /// caller atomically promotes it to `stream`.
    private var startingStream: SCStream?
    private var startingStreamStopError: Error?
    private var stream: SCStream?
    private var startGeneration: UInt64 = 0
    /// Set when a start attempt gave up. `SCStream.startCapture()` is not
    /// cancellation-aware, so a late-completing start must stop its own stream
    /// instead of publishing it.
    private var startFailed = false
    private var failureGate = SystemAudioCaptureFailureGate()
    private var outputFile: FileHandle?
    private var outputURL: URL?
    private var totalBytesWritten = 0
    /// SCStream delivers sample buffers on this queue, so `outputFile` and
    /// `totalBytesWritten` are only touched from here once capture is running.
    private let sampleHandlerQueue = DispatchQueue(label: "com.muesli.system-audio")
    private let recordingFlag = ManagedAtomic(false)
    private let pausedFlag = ManagedAtomic(false)
    private(set) var isRecording: Bool {
        get { recordingFlag.load(ordering: .acquiring) }
        set { recordingFlag.store(newValue, ordering: .releasing) }
    }
    private(set) var isPaused: Bool {
        get { pausedFlag.load(ordering: .acquiring) }
        set { pausedFlag.store(newValue, ordering: .releasing) }
    }

    private static let sampleRate: Double = 16_000
    private static let channels: Int = 1
    private let diagnosticsLock = OSAllocatedUnfairLock(initialState: DiagnosticsState())

    private struct DiagnosticsState {
        var callbackCount = 0
        var bufferCount = 0
        var emptyBufferCount = 0
        var unsupportedFormatCount = 0
        var inputByteCount = 0
        var bytesWritten = 0
        var sourceSampleRate: Double = 0
        var sourceChannels: UInt32 = 0
        var preConversion = AudioSampleStats()
        var postConversion = AudioSampleStats()
    }

    var diagnosticsSnapshot: SystemAudioCaptureDiagnosticsSnapshot {
        diagnosticsLock.withLock { state in
            SystemAudioCaptureDiagnosticsSnapshot(
                backend: "ScreenCaptureKit",
                callbackCount: state.callbackCount,
                bufferCount: state.bufferCount,
                emptyBufferCount: state.emptyBufferCount,
                unsupportedFormatCount: state.unsupportedFormatCount,
                inputByteCount: state.inputByteCount,
                bytesWritten: state.bytesWritten,
                sourceSampleRate: state.sourceSampleRate,
                sourceChannels: state.sourceChannels,
                preConversion: state.preConversion.snapshot(),
                postConversion: state.postConversion.snapshot()
            )
        }
    }

    override init() {
        super.init()
    }

    func start() async throws {
        guard !isRecording else { return }

        // Create output WAV file
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: url.path) else {
            throw NSError(domain: "SystemAudio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open output file",
            ])
        }
        file.write(WavWriter.header(dataSize: 0))
        outputFile = file
        outputURL = url
        totalBytesWritten = 0
        isRecording = true
        isPaused = false
        let generation = streamStateQueue.sync { () -> UInt64 in
            self.startGeneration &+= 1
            self.startFailed = false
            return self.startGeneration
        }

        do {
            let startedStream = try await SystemAudioStartupDeadline.wait(timeout: 5) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.makeStartedStream(generation: generation)
            } onLateSuccess: { [weak self] stream in
                // `startCapture()` ignores task cancellation. If the deadline or
                // caller wins first, tear down a capture that completes later.
                self?.streamStateQueue.sync {
                    guard self?.startGeneration == generation,
                          self?.startingStream === stream else { return }
                    self?.startingStream = nil
                    self?.startingStreamStopError = nil
                }
                try? await stream.stopCapture()
            } onLateFailure: { [weak self] _ in
                self?.streamStateQueue.sync {
                    guard self?.startGeneration == generation else { return }
                    self?.startingStream = nil
                    self?.startingStreamStopError = nil
                }
            }
            if Task.isCancelled {
                streamStateQueue.sync {
                    guard self.startGeneration == generation,
                          self.startingStream === startedStream else { return }
                    self.startingStream = nil
                    self.startingStreamStopError = nil
                }
                try? await startedStream.stopCapture()
                throw CancellationError()
            }
            let publicationError = streamStateQueue.sync { () -> Error? in
                guard self.startGeneration == generation,
                      self.startingStream === startedStream else { return CancellationError() }
                self.startingStream = nil
                if let error = self.startingStreamStopError {
                    self.startingStreamStopError = nil
                    self.startFailed = true
                    return error
                }
                guard !self.startFailed else { return CancellationError() }
                self.stream = startedStream
                self.failureGate.activate()
                return nil
            }
            if let publicationError {
                try? await startedStream.stopCapture()
                throw publicationError
            }
            fputs("[system-audio] SCStream capture started\n", stderr)
        } catch {
            fputs("[system-audio] SCStream start failed: \(error)\n", stderr)
            await cleanupFailedStart(generation: generation)
            throw error
        }
    }

    func stop() async -> URL? {
        guard isRecording || outputFile != nil || outputURL != nil else { return nil }
        isRecording = false
        isPaused = false

        let activeStream = streamStateQueue.sync { () -> SCStream? in
            self.failureGate.deactivate()
            let current = self.stream
            self.stream = nil
            return current
        }
        if let activeStream {
            try? await activeStream.stopCapture()
        }

        // Finalize WAV on the sample-handler queue so a callback that is already
        // past the isRecording gate finishes its write before the header rewrite
        // and close — otherwise it corrupts the header or writes to a closed file.
        let writtenBytes = sampleHandlerQueue.sync { () -> Int in
            onPCMSamples = nil
            onSystemAudioInterruption = nil
            onSystemAudioFailure = nil
            onSystemAudioRecovery = nil
            let bytes = totalBytesWritten
            if let file = outputFile {
                let header = WavWriter.header(dataSize: bytes)
                file.seek(toFileOffset: 0)
                file.write(header)
                file.closeFile()
            }
            outputFile = nil
            totalBytesWritten = 0
            return bytes
        }

        let completedURL = outputURL
        outputURL = nil

        fputs("[system-audio] capture stopped, \(writtenBytes) bytes written\n", stderr)
        return completedURL
    }

    func pause() {
        guard isRecording else { return }
        isPaused = true
    }

    func resume() {
        guard isRecording else { return }
        isPaused = false
    }

    // MARK: - SCStream setup

    private func makeStartedStream(generation: UInt64) async throws -> SCStream {
        // Get shareable content (required to create a filter)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Create a filter that captures all audio — use a display filter with audio only
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudio", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No display found for SCStream",
            ])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // Audio-only: disable video capture
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum (can't set 0)
        config.showsCursor = false

        // Audio configuration
        config.capturesAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = Self.channels
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        let mayStart = streamStateQueue.sync { () -> Bool in
            guard self.startGeneration == generation, !self.startFailed else { return false }
            self.startingStream = stream
            self.startingStreamStopError = nil
            return true
        }
        guard mayStart else { throw CancellationError() }
        do {
            try await stream.startCapture()
        } catch {
            streamStateQueue.sync {
                guard self.startGeneration == generation,
                      self.startingStream === stream else { return }
                self.startingStream = nil
                self.startingStreamStopError = nil
            }
            throw error
        }
        return stream
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRecording, !isPaused else { return }
        diagnosticsLock.withLock { $0.callbackCount += 1 }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            diagnosticsLock.withLock { $0.emptyBufferCount += 1 }
            return
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else {
            diagnosticsLock.withLock { $0.emptyBufferCount += 1 }
            return
        }

        // Get the audio format
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }
        diagnosticsLock.withLock { state in
            state.bufferCount += 1
            state.inputByteCount += length
            state.sourceSampleRate = asbd.mSampleRate
            state.sourceChannels = asbd.mChannelsPerFrame
        }

        // Extract raw audio bytes
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        // Convert float32 samples to int16 PCM for WAV
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floatCount = length / MemoryLayout<Float>.size
            let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: floatCount)

            // If stereo, mix down to mono
            let outputSamples: Int
            if Int(asbd.mChannelsPerFrame) > 1 {
                let channelCount = Int(asbd.mChannelsPerFrame)
                outputSamples = floatCount / channelCount
            } else {
                outputSamples = floatCount
            }

            var int16Data = Data(count: outputSamples * 2)
            var preConversion = [Float]()
            preConversion.reserveCapacity(outputSamples)
            int16Data.withUnsafeMutableBytes { rawBuffer in
                let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
                let channels = Int(asbd.mChannelsPerFrame)
                for i in 0..<outputSamples {
                    var sample: Float
                    if channels > 1 {
                        // Average channels for mono mixdown
                        var sum: Float = 0
                        for ch in 0..<channels {
                            sum += floatPointer[i * channels + ch]
                        }
                        sample = sum / Float(channels)
                    } else {
                        sample = floatPointer[i]
                    }
                    preConversion.append(sample)
                    // Clamp and convert to int16
                    let clamped = max(-1.0, min(1.0, sample))
                    int16Buffer[i] = Int16(clamped * 32767.0)
                }
            }
            let int16Samples = int16Data.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Int16.self))
            }
            let bytesToWrite = int16Data.count
            let preConversionSamples = preConversion

            outputFile?.write(int16Data)
            totalBytesWritten += bytesToWrite
            diagnosticsLock.withLock { state in
                state.bytesWritten += bytesToWrite
                state.preConversion.addFloats(preConversionSamples)
                state.postConversion.addInt16(int16Samples)
            }
            onPCMSamples?(int16Samples)
        } else {
            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  asbd.mBitsPerChannel == 16,
                  abs(asbd.mSampleRate - Self.sampleRate) < 1.0,
                  (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            else {
                diagnosticsLock.withLock { $0.unsupportedFormatCount += 1 }
                fputs("[system-audio] unsupported SCStream integer PCM format rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)\n", stderr)
                return
            }

            let rawData = Data(bytes: dataPointer, count: length)
            let interleavedSamples = rawData.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Int16.self))
            }
            let channels = max(Int(asbd.mChannelsPerFrame), 1)
            let int16Samples: [Int16]
            if channels == 1 {
                int16Samples = interleavedSamples
            } else {
                let frameCount = interleavedSamples.count / channels
                int16Samples = (0..<frameCount).map { frame in
                    var sum = 0
                    for channel in 0..<channels {
                        sum += Int(interleavedSamples[frame * channels + channel])
                    }
                    return Int16(clamping: sum / channels)
                }
            }
            let int16Data = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }
            outputFile?.write(int16Data)
            totalBytesWritten += int16Data.count
            diagnosticsLock.withLock { state in
                state.bytesWritten += int16Data.count
                state.preConversion.addInt16(interleavedSamples)
                state.postConversion.addInt16(int16Samples)
            }
            onPCMSamples?(int16Samples)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let shouldReport = streamStateQueue.sync { () -> Bool in
            if self.startingStream === stream {
                if !self.startFailed, self.startingStreamStopError == nil {
                    self.startingStreamStopError = error
                }
                return false
            }
            guard self.stream === stream else { return false }
            return self.failureGate.shouldReportUnexpectedStop()
        }
        guard shouldReport else { return }
        onSystemAudioInterruption?()
        onSystemAudioFailure?(error)
    }

    private func cleanupFailedStart(generation: UInt64) async {
        // A timed-out start can still be inside `startCapture()`, and whatever it
        // started must be stopped — dropping the reference leaves a live capture
        // (recording indicator lit, self retained) for the rest of the session.
        let cleanup = streamStateQueue.sync { () -> (isCurrent: Bool, stream: SCStream?) in
            guard self.startGeneration == generation else { return (false, nil) }
            self.startFailed = true
            self.failureGate.deactivate()
            let current = self.stream
            self.stream = nil
            if self.startingStream == nil {
                self.startingStreamStopError = nil
            }
            return (true, current)
        }
        guard cleanup.isCurrent else { return }
        isPaused = false

        // A start that timed out can leave the stream delivering buffers, so close
        // on the sample-handler queue for the same reason stop() does.
        sampleHandlerQueue.sync {
            onPCMSamples = nil
            onSystemAudioInterruption = nil
            onSystemAudioFailure = nil
            onSystemAudioRecovery = nil
            if let file = outputFile {
                file.closeFile()
            }
            outputFile = nil
            totalBytesWritten = 0
        }

        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        // Keep concurrent `start()` calls excluded until this attempt's shared
        // file state has been closed. The orphaned stream can stop afterward.
        isRecording = false

        if let orphanedStream = cleanup.stream {
            try? await orphanedStream.stopCapture()
        }
    }
}

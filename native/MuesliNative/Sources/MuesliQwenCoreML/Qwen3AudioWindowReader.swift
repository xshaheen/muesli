import AVFoundation
import Foundation

public struct Qwen3AudioWindowDescriptor: Equatable, Sendable {
    public let index: Int
    public let totalCount: Int
    public let startSample: Int
    public let endSample: Int

    public var sampleCount: Int { endSample - startSample }
    public var startTime: TimeInterval {
        Double(startSample) / Double(Qwen3AudioWindowReader.targetSampleRate)
    }
    public var endTime: TimeInterval {
        Double(endSample) / Double(Qwen3AudioWindowReader.targetSampleRate)
    }
}

public struct Qwen3AudioWindow: Sendable {
    public let descriptor: Qwen3AudioWindowDescriptor
    public let samples: [Float]
}

public enum Qwen3AudioWindowReaderError: Error, LocalizedError, Equatable, Sendable {
    case invalidAudio(String)
    case invalidDuration
    case allocationFailed
    case readFailed(window: Int, detail: String)
    case conversionFailed(window: Int, detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAudio(let detail): "Could not open Qwen audio: \(detail)"
        case .invalidDuration: "Qwen audio has an invalid or empty duration."
        case .allocationFailed: "Could not allocate a bounded Qwen audio window."
        case .readFailed(let window, let detail): "Could not read Qwen audio window \(window): \(detail)"
        case .conversionFailed(let window, let detail): "Could not convert Qwen audio window \(window): \(detail)"
        }
    }
}

/// Bounded AVFoundation reader shared by app and CLI. Planning occurs in the
/// 16 kHz target sample domain so every target sample belongs to at least one
/// window, including source files with fractional or non-16 kHz sample rates.
public struct Qwen3AudioWindowReader: Sendable {
    public static let targetSampleRate = 16_000
    public static let windowSampleCount = 20 * targetSampleRate
    public static let overlapSampleCount = 2 * targetSampleRate
    public static let strideSampleCount = windowSampleCount - overlapSampleCount

    public init() {}

    public func duration(of url: URL) throws -> TimeInterval {
        let file = try open(url)
        let sampleRate = file.processingFormat.sampleRate
        guard file.length > 0, sampleRate > 0, sampleRate.isFinite else {
            throw Qwen3AudioWindowReaderError.invalidDuration
        }
        let duration = Double(file.length) / sampleRate
        guard duration > 0, duration.isFinite else {
            throw Qwen3AudioWindowReaderError.invalidDuration
        }
        return duration
    }

    public func descriptors(forDuration duration: TimeInterval) throws -> [Qwen3AudioWindowDescriptor] {
        guard duration > 0, duration.isFinite else {
            throw Qwen3AudioWindowReaderError.invalidDuration
        }
        let totalSamples = max(1, Int((duration * Double(Self.targetSampleRate)).rounded()))
        return Self.descriptors(totalSampleCount: totalSamples)
    }

    public static func descriptors(totalSampleCount: Int) -> [Qwen3AudioWindowDescriptor] {
        guard totalSampleCount > 0 else { return [] }
        var ranges: [(Int, Int)] = []
        var start = 0
        while start < totalSampleCount {
            let end = min(start + windowSampleCount, totalSampleCount)
            ranges.append((start, end))
            if end == totalSampleCount { break }
            start += strideSampleCount
        }
        return ranges.enumerated().map { offset, range in
            Qwen3AudioWindowDescriptor(
                index: offset,
                totalCount: ranges.count,
                startSample: range.0,
                endSample: range.1
            )
        }
    }

    public func read(_ descriptor: Qwen3AudioWindowDescriptor, from url: URL) throws -> Qwen3AudioWindow {
        let file = try open(url)
        let sourceFormat = file.processingFormat
        let sourceRate = sourceFormat.sampleRate
        guard sourceRate > 0, sourceRate.isFinite else {
            throw Qwen3AudioWindowReaderError.invalidDuration
        }

        let sourceStart = AVAudioFramePosition(floor(Double(descriptor.startSample) * sourceRate / Double(Self.targetSampleRate)))
        let unclampedEnd = AVAudioFramePosition(ceil(Double(descriptor.endSample) * sourceRate / Double(Self.targetSampleRate)))
        let sourceEnd = min(max(unclampedEnd, sourceStart + 1), file.length)
        let framesToRead = max(0, sourceEnd - sourceStart)
        guard framesToRead > 0,
              framesToRead <= AVAudioFramePosition(UInt32.max),
              let input = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(framesToRead)
              )
        else { throw Qwen3AudioWindowReaderError.allocationFailed }

        do {
            file.framePosition = sourceStart
            try file.read(into: input, frameCount: AVAudioFrameCount(framesToRead))
        } catch {
            throw Qwen3AudioWindowReaderError.readFailed(
                window: descriptor.index,
                detail: error.localizedDescription
            )
        }
        guard input.frameLength > 0 else {
            throw Qwen3AudioWindowReaderError.readFailed(window: descriptor.index, detail: "empty read")
        }

        let samples: [Float]
        if sourceFormat.sampleRate == Double(Self.targetSampleRate),
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let channel = input.floatChannelData?[0] {
            samples = Array(UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
        } else {
            samples = try convert(
                input,
                descriptor: descriptor,
                sourceFormat: sourceFormat
            )
        }
        return Qwen3AudioWindow(descriptor: descriptor, samples: samples)
    }

    private func open(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw Qwen3AudioWindowReaderError.invalidAudio(error.localizedDescription)
        }
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        descriptor: Qwen3AudioWindowDescriptor,
        sourceFormat: AVAudioFormat
    ) throws -> [Float] {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.targetSampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw Qwen3AudioWindowReaderError.allocationFailed
        }
        let capacity = AVAudioFrameCount(max(descriptor.sampleCount + 64, 1))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw Qwen3AudioWindowReaderError.allocationFailed
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw Qwen3AudioWindowReaderError.conversionFailed(
                window: descriptor.index,
                detail: conversionError?.localizedDescription ?? "unknown conversion error"
            )
        }
        let count = min(Int(output.frameLength), descriptor.sampleCount)
        guard count > 0 else {
            throw Qwen3AudioWindowReaderError.conversionFailed(window: descriptor.index, detail: "empty output")
        }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
}

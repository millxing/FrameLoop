import Foundation

/// Opens what AVFoundation cannot (MKV, AVI, FLV, GIF, AV1) by making a playable MP4 copy with ffmpeg.
/// ffmpeg is optional: it is read from Homebrew, never bundled.
nonisolated enum FFmpeg {
    enum Plan { case remux(hevc: Bool), transcode }

    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "FrameLoop", directoryHint: .isDirectory)
    }

    static func removeAllProxies() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func tool(_ name: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let override = name == "ffmpeg" ? environment["FRAMELOOP_FFMPEG_PATH"] : environment["FRAMELOOP_FFPROBE_PATH"]
        return [override, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// What to do with a probed file: copy H.264 or HEVC into an MP4 (seconds, no quality loss), otherwise re-encode.
    static func plan(extension ext: String, streams: [[String: Any]]) -> Plan {
        if ext == "gif" { return .transcode }
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let codec = video?["codec_name"] as? String
        let pixels = video?["pix_fmt"] as? String ?? ""
        if codec == "h264", ["yuv420p", "yuvj420p"].contains(pixels) { return .remux(hevc: false) }
        if codec == "hevc", pixels.hasPrefix("yuv420p") { return .remux(hevc: true) }
        return .transcode
    }

    static func arguments(plan: Plan, input: URL, output: URL, hasAudio: Bool, hasX264: Bool) -> [String] {
        var args = ["-y", "-i", input.path, "-map", "0:v:0"]
        if hasAudio { args += ["-map", "0:a:0?"] }
        switch plan {
        case .remux(let hevc):
            args += ["-c:v", "copy"]
            if hevc { args += ["-tag:v", "hvc1"] }
        case .transcode:
            args += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-fps_mode", "passthrough"]
            args += hasX264
                ? ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p"]
                : ["-c:v", "h264_videotoolbox", "-b:v", "20M", "-pix_fmt", "yuv420p"]
        }
        if hasAudio { args += ["-c:a", "aac", "-b:a", "256k", "-ar", "48000"] } else { args += ["-an"] }
        return args + ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
    }

    @concurrent
    static func makePlayableCopy(of input: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            throw FFmpegError.missing(input.pathExtension.uppercased())
        }
        let probeText = try await run(ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", input.path])
        let json = (try? JSONSerialization.jsonObject(with: Data(probeText.utf8))) as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []
        guard streams.contains(where: { $0["codec_type"] as? String == "video" }) else { throw MediaError.noVideo }
        let duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        let hasAudio = streams.contains { $0["codec_type"] as? String == "audio" }
        let encoders = (try? await run(ffmpeg, ["-hide_banner", "-encoders"])) ?? ""
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: UUID().uuidString + ".mp4")
        let args = arguments(plan: plan(extension: input.pathExtension.lowercased(), streams: streams), input: input,
                             output: output, hasAudio: hasAudio, hasX264: encoders.contains("libx264"))
        do {
            _ = try await run(ffmpeg, args, duration: duration, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// Runs a tool to the end and returns its output. Cancelling the task stops the tool.
    private static func run(_ tool: URL, _ arguments: [String], duration: Double = 0,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = Collector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            collector.append(text)
            if duration > 0, let progress,
               let match = text.matches(of: /out_time_(?:ms|us)=(\d+)/).last, let micro = Double(match.1) {
                progress(min(1, micro / 1_000_000 / duration))
            }
        }
        let errors = Collector()
        err.fileHandleForReading.readabilityHandler = { errors.append(String(decoding: $0.availableData, as: UTF8.self)) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    if finished.terminationStatus == 0 {
                        continuation.resume(returning: collector.text)
                    } else if finished.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        let lines = errors.text.split(separator: "\n").suffix(3).joined(separator: "\n")
                        continuation.resume(throwing: FFmpegError.failed(lines.isEmpty ? "\(tool.lastPathComponent) failed." : lines))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

nonisolated enum FFmpegError: LocalizedError {
    case missing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let ext): "\(ext) files need ffmpeg. Install it with: brew install ffmpeg"
        case .failed(let text): "ffmpeg could not prepare this file.\n\(text)"
        }
    }
}

/// Collects a tool's output from a background thread.
nonisolated final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

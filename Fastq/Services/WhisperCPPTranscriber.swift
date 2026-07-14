import Foundation
import whisper

enum VoiceError: LocalizedError {
    case format
    case model
    case whisper(String)

    var errorDescription: String? {
        switch self {
        case .format: return "Couldn’t configure microphone audio format."
        case .model: return "Whisper model is missing."
        case .whisper(let message): return message
        }
    }
}

/// Thin Swift wrapper around the whisper.cpp C API (linked via xcframework).
final class WhisperCPPTranscriber: @unchecked Sendable {
    static let shared = WhisperCPPTranscriber()

    private let lock = NSLock()
    private var ctx: OpaquePointer?
    private var loadedModelPath: String?

    func transcribe(
        samples: [Float],
        modelPath: String,
        translateToEnglish: Bool
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try self.transcribeSync(
                samples: samples,
                modelPath: modelPath,
                translateToEnglish: translateToEnglish
            )
        }.value
    }

    private func transcribeSync(
        samples: [Float],
        modelPath: String,
        translateToEnglish: Bool
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if loadedModelPath != modelPath {
            if let ctx {
                whisper_free(ctx)
                self.ctx = nil
            }
            guard let newCtx = whisper_init_from_file_with_params(
                modelPath,
                whisper_context_default_params()
            ) else {
                throw VoiceError.model
            }
            ctx = newCtx
            loadedModelPath = modelPath
        }

        guard let ctx else { throw VoiceError.model }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = false
        params.translate = translateToEnglish
        params.no_context = true
        params.single_segment = false
        params.temperature = 0
        // Auto-detect source language; translate forces English output when translate=true.
        params.language = nil

        let result = samples.withUnsafeBufferPointer { buf -> Int32 in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard result == 0 else {
            throw VoiceError.whisper("Whisper failed (code \(result))")
        }

        let n = whisper_full_n_segments(ctx)
        var parts: [String] = []
        parts.reserveCapacity(Int(n))
        for i in 0..<n {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                parts.append(String(cString: cstr))
            }
        }
        return parts.joined(separator: " ")
    }

    deinit {
        if let ctx {
            whisper_free(ctx)
        }
    }
}

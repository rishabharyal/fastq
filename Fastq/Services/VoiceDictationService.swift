import Foundation
import AVFoundation
import Speech
import SwiftUI
import Combine

/// Hold-to-talk dictation with live partial transcripts (Speech framework).
/// Optimized for low-latency “text appears as you speak” UX.
@MainActor
final class VoiceDictationService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requestingAccess
        case listening
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 0…1 mic level for pulse animation.
    @Published private(set) var level: Float = 0
    /// Latest partial / final transcript for this hold session (no baseline prefix).
    @Published private(set) var liveTranscript: String = ""

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Prompt text before this hold began — live results replace from here.
    private var baselinePrompt = ""
    private var onPromptUpdate: ((String) -> Void)?

    var isListening: Bool { phase == .listening }

    // MARK: - Public

    func prepare() {
        // Warm recognizer; prefer Indian English for South-Asian accents, fall back to US.
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN"))
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
                ?? SFSpeechRecognizer()
        }
        // Don't request speech authorization here — dictation is opt-in via
        // the mic button, and beginHold asks on first use. Prompting from
        // prepare() spammed the permission dialog on every panel open.
    }

    /// Begin hold-to-talk. `onPromptUpdate` receives the full prompt (baseline + live text).
    func beginHold(currentPrompt: String, onPromptUpdate: @escaping (String) -> Void) {
        guard phase != .listening else { return }
        self.baselinePrompt = currentPrompt
        self.onPromptUpdate = onPromptUpdate
        liveTranscript = ""
        level = 0

        Task { await startListening() }
    }

    func endHold() {
        guard phase == .listening || phase == .requestingAccess else { return }
        stopListening(finalize: true)
    }

    func cancelHold() {
        guard phase == .listening || phase == .requestingAccess else { return }
        // Revert to baseline (discard partials).
        onPromptUpdate?(baselinePrompt)
        stopListening(finalize: false)
    }

    // MARK: - Engine

    private func startListening() async {
        phase = .requestingAccess

        let micOK = await requestMicAccess()
        guard micOK else {
            phase = .failed("Microphone access is required. Enable it in System Settings → Privacy → Microphone.")
            return
        }
        let speechOK = await requestSpeechAccess()
        guard speechOK else {
            phase = .failed("Speech recognition access is required. Enable it in System Settings → Privacy → Speech Recognition.")
            return
        }

        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN"))
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
                ?? SFSpeechRecognizer()
        }
        guard let recognizer, recognizer.isAvailable else {
            phase = .failed("Speech recognition isn’t available right now.")
            return
        }

        // Tear down any previous session cleanly.
        stopEngineOnly()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // Adds punctuation; helps prompt quality.
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            phase = .failed("No active microphone input.")
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            Self.publishLevel(from: buffer) { level in
                Task { @MainActor in
                    // Light smoothing — keeps the pulse calm.
                    guard let self else { return }
                    self.level = self.level * 0.65 + level * 0.35
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .listening

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.liveTranscript = text
                    self.pushPrompt(with: text)
                    if result.isFinal {
                        self.stopListening(finalize: true)
                    }
                }
                if let error, (error as NSError).code != 216 /* canceled */ {
                    // Don't surface cancellation as failure when user released Space.
                    if self.phase == .listening {
                        self.phase = .failed(error.localizedDescription)
                        self.stopEngineOnly()
                    }
                }
            }
        }
    }

    private func stopListening(finalize: Bool) {
        request?.endAudio()
        stopEngineOnly()
        task?.cancel()
        task = nil
        request = nil
        level = 0
        if finalize, !liveTranscript.isEmpty {
            pushPrompt(with: liveTranscript)
        }
        phase = .idle
        onPromptUpdate = nil
    }

    private func stopEngineOnly() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func pushPrompt(with spoken: String) {
        guard !spoken.isEmpty else {
            onPromptUpdate?(baselinePrompt)
            return
        }
        var merged = baselinePrompt
        if merged.isEmpty {
            merged = spoken
        } else if merged.hasSuffix(" ") || merged.hasSuffix("\n") {
            merged += spoken
        } else {
            merged += " " + spoken
        }
        onPromptUpdate?(merged)
    }

    // MARK: - Permissions / metering

    private func requestMicAccess() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                cont.resume(returning: ok)
            }
        }
    }

    private func requestSpeechAccess() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    private static func publishLevel(from buffer: AVAudioPCMBuffer, emit: @escaping (Float) -> Void) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        // Stride for speed — enough for a pulse.
        let step = max(1, n / 128)
        var count = 0
        var i = 0
        while i < n {
            let s = ch[i]
            sum += s * s
            count += 1
            i += step
        }
        let rms = sqrt(sum / Float(max(count, 1)))
        emit(min(1, rms * 10))
    }
}

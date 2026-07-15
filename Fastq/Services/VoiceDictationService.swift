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
    /// False when Siri AND Dictation are both off in System Settings — macOS
    /// blocks SFSpeechRecognizer entirely in that state, no matter what the
    /// app does. The UI uses this to show a crossed-out mic and point the
    /// user at the toggle instead of failing mid-recording.
    @Published private(set) var systemSpeechAvailable = true

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Prompt text before this hold began, plus any utterances already
    /// banked during this session — live results replace from here.
    private var baselinePrompt = ""
    private var onPromptUpdate: ((String) -> Void)?
    /// Consecutive transient recognition errors survived by restarting.
    private var errorRestarts = 0

    var isListening: Bool { phase == .listening }

    // MARK: - Public

    func prepare() {
        refreshSystemSpeechAvailability()
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

    /// Re-reads the Siri/Dictation toggles so the mic icon recovers as soon as
    /// the user flips either one in System Settings.
    func refreshSystemSpeechAvailability() {
        systemSpeechAvailable = Self.siriOrDictationEnabled()
    }

    static let dictationDisabledMessage =
        "Dictation is turned off on this Mac. Apple speech recognition needs Siri or Dictation enabled — turn on Dictation in System Settings → Keyboard."

    private static func siriOrDictationEnabled() -> Bool {
        let domain = "com.apple.assistant.support" as CFString
        let dictation = (CFPreferencesCopyAppValue("Dictation Enabled" as CFString, domain) as? NSNumber)?.boolValue ?? false
        let siri = (CFPreferencesCopyAppValue("Assistant Enabled" as CFString, domain) as? NSNumber)?.boolValue ?? false
        return dictation || siri
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
        refreshSystemSpeechAvailability()
        guard systemSpeechAvailable else {
            phase = .failed(Self.dictationDisabledMessage)
            return
        }
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

        let request = makeRequest()
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
        errorRestarts = 0
        beginRecognitionTask()
    }

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        // Adds punctuation; helps prompt quality.
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        return request
    }

    private func beginRecognitionTask() {
        guard let recognizer, let request else { return }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error)
            }
        }
    }

    /// Apple finalizes an utterance after a few seconds of silence; the next
    /// partial then starts from scratch. To keep one hold-to-talk session
    /// alive across pauses, finished text is banked into `baselinePrompt`
    /// and recognition restarts on a fresh request (mic stays hot).
    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { errorRestarts = 0 }

            // Reset detection: after a silence gap the transcript sometimes
            // restarts mid-task without an isFinal. A partial that collapses
            // to under half the previous length is a new utterance, not a
            // correction — bank the old text before accepting the new one.
            if !liveTranscript.isEmpty, liveTranscript.count >= 12, text.count < liveTranscript.count / 2 {
                commitLiveTranscript()
            }

            liveTranscript = text
            pushPrompt(with: text)

            if result.isFinal, phase == .listening {
                // Utterance ended (pause) — bank it and keep listening.
                commitLiveTranscript()
                restartRecognitionTask()
            }
        }

        if let error {
            let ns = error as NSError
            // 216 / 301: task canceled (we stopped it ourselves).
            if ns.code == 216 || ns.code == 301 { return }
            guard phase == .listening else { return }

            // kAFAssistantErrorDomain 1700: Siri/Dictation got turned
            // off — swap the raw system string for actionable copy.
            if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1700
                || ns.localizedDescription.localizedCaseInsensitiveContains("Siri and Dictation") {
                systemSpeechAvailable = false
                phase = .failed(Self.dictationDisabledMessage)
                stopEngineOnly()
                return
            }

            // Transient errors (e.g. "no speech detected" after a long gap):
            // keep the session going instead of failing the whole dictation.
            if errorRestarts < 3 {
                errorRestarts += 1
                commitLiveTranscript()
                restartRecognitionTask()
            } else {
                phase = .failed(error.localizedDescription)
                stopEngineOnly()
            }
        }
    }

    private func restartRecognitionTask() {
        task?.cancel()
        task = nil
        let request = makeRequest()
        self.request = request // the mic tap appends to `self.request`
        beginRecognitionTask()
    }

    /// Bank the current partial into the baseline so the next utterance
    /// appends instead of replacing it.
    private func commitLiveTranscript() {
        guard !liveTranscript.isEmpty else { return }
        baselinePrompt = Self.merged(baselinePrompt, liveTranscript)
        liveTranscript = ""
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
        onPromptUpdate?(Self.merged(baselinePrompt, spoken))
    }

    private static func merged(_ base: String, _ spoken: String) -> String {
        guard !spoken.isEmpty else { return base }
        if base.isEmpty { return spoken }
        if base.hasSuffix(" ") || base.hasSuffix("\n") { return base + spoken }
        return base + " " + spoken
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

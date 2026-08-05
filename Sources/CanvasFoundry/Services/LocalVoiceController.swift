import AVFoundation
import Combine
import Foundation
import Speech

/// Energy-based endpoint detection that runs entirely inside the audio tap.
/// It does not interpret audio; it only distinguishes sustained speech from
/// silence and enforces bounded recording durations.
final class LocalVoiceActivityDetector: @unchecked Sendable {
    enum Endpoint: Equatable {
        case silence
        case noSpeech
        case maximumDuration
    }

    struct Update: Equatable {
        let level: Double
        let endpoint: Endpoint?
    }

    private let lock = NSLock()
    private let silenceDuration: TimeInterval
    private let noSpeechTimeout: TimeInterval
    private let maximumDuration: TimeInterval
    private let minimumSpeechDuration: TimeInterval
    private var elapsed: TimeInterval = 0
    private var speechRun: TimeInterval = 0
    private var trailingSilence: TimeInterval = 0
    private var lastLevelUpdate: TimeInterval = 0
    private var noiseFloor = -60.0
    private var hasSpeech = false
    private var didReachEndpoint = false

    init(
        silenceDuration: TimeInterval = 1.0,
        noSpeechTimeout: TimeInterval = 8.0,
        maximumDuration: TimeInterval = 30.0,
        minimumSpeechDuration: TimeInterval = 0.12
    ) {
        self.silenceDuration = silenceDuration
        self.noSpeechTimeout = noSpeechTimeout
        self.maximumDuration = maximumDuration
        self.minimumSpeechDuration = minimumSpeechDuration
    }

    func process(decibels: Double, duration: TimeInterval) -> Update? {
        lock.lock()
        defer { lock.unlock() }
        guard !didReachEndpoint else { return nil }

        elapsed += duration
        if !hasSpeech, decibels < -35 {
            noiseFloor = noiseFloor * 0.96 + decibels * 0.04
        }
        let speechThreshold = min(max(noiseFloor + 12, -45), -28)
        let soundsLikeSpeech = decibels >= speechThreshold

        if soundsLikeSpeech {
            speechRun += duration
            trailingSilence = 0
            if speechRun >= minimumSpeechDuration { hasSpeech = true }
        } else if hasSpeech {
            trailingSilence += duration
        } else {
            speechRun = max(0, speechRun - duration * 0.5)
        }

        let endpoint: Endpoint?
        let timingTolerance = 0.000_001
        if hasSpeech, trailingSilence + timingTolerance >= silenceDuration {
            endpoint = .silence
        } else if !hasSpeech, elapsed + timingTolerance >= noSpeechTimeout {
            endpoint = .noSpeech
        } else if elapsed + timingTolerance >= maximumDuration {
            endpoint = .maximumDuration
        } else {
            endpoint = nil
        }

        if endpoint != nil { didReachEndpoint = true }
        let shouldPublishLevel = elapsed - lastLevelUpdate >= 0.06
        guard shouldPublishLevel || endpoint != nil else { return nil }
        lastLevelUpdate = elapsed
        let level = min(max((decibels + 60) / 36, 0), 1)
        return Update(level: level, endpoint: endpoint)
    }
}

/// A deliberately local-only speech adapter for the command bar.
///
/// Foundry never permits Speech to fall back to Apple's servers. If the current
/// locale has no on-device recognizer, voice input stays unavailable until a
/// fully local fallback (such as WhisperKit) is installed.
@MainActor
final class LocalVoiceController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case listening
        case finishing
        case unavailable(String)

        var isRecording: Bool { self == .listening }
    }

    struct CompletedTranscript: Equatable, Identifiable {
        let id = UUID()
        let text: String
    }

    struct Notice: Equatable, Identifiable {
        let id = UUID()
        let message: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var completedTranscript: CompletedTranscript?
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var notice: Notice?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var inputTapInstalled = false
    private var permissionRequestID: UUID?
    private var recognitionID: UUID?
    private var activityDetector: LocalVoiceActivityDetector?

    var isListening: Bool { phase.isRecording }

    func toggle() {
        switch phase {
        case .idle, .unavailable:
            begin()
        case .requestingPermission, .listening, .finishing:
            cancel()
        }
    }

    func begin() {
        guard Self.hasPrivacyDescriptions else {
            phase = .unavailable(
                "Run Foundry as a macOS app so it can request microphone permission."
            )
            return
        }

        phase = .requestingPermission
        notice = nil
        audioLevel = 0
        let requestID = UUID()
        permissionRequestID = requestID
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            Task { @MainActor [weak self] in
                guard let self, self.permissionRequestID == requestID else { return }
                guard speechStatus == .authorized else {
                    self.permissionRequestID = nil
                    self.phase = .unavailable(Self.speechAuthorizationMessage(speechStatus))
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    Task { @MainActor [weak self] in
                        guard let self, self.permissionRequestID == requestID else { return }
                        self.permissionRequestID = nil
                        guard granted else {
                            self.phase = .unavailable(
                                "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
                            )
                            return
                        }
                        self.startOnDeviceRecognition()
                    }
                }
            }
        }
    }

    func finishRecording() {
        guard audioEngine.isRunning else {
            phase = .idle
            return
        }
        audioEngine.stop()
        removeInputTap()
        recognitionRequest?.endAudio()
        activityDetector = nil
        audioLevel = 0
        phase = .finishing

        // On-device recognition normally emits an isFinal result after
        // endAudio(), but don't leave the UI spinning forever if it doesn't.
        let pendingRecognitionID = recognitionID
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                  self.phase == .finishing,
                  self.recognitionID == pendingRecognitionID else { return }
            if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.stopAudioCapture()
                self.phase = .idle
                self.notice = Notice(
                    message: "I heard audio but couldn’t transcribe it. Tap the microphone to try again."
                )
            } else {
                self.completeRecognition()
            }
        }
    }

    func cancel() {
        permissionRequestID = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognitionID = nil
        activityDetector = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()
        transcript = ""
        audioLevel = 0
        phase = .idle
    }

    private func startOnDeviceRecognition() {
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else {
            phase = .unavailable("Speech recognition is currently unavailable.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            let language = Locale.current.localizedString(
                forIdentifier: Locale.current.identifier
            ) ?? "this language"
            phase = .unavailable(
                "On-device recognition isn't available for \(language). Foundry will not use cloud recognition."
            )
            return
        }

        cancelActiveRecognition()
        self.recognizer = recognizer
        transcript = ""
        audioLevel = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            phase = .unavailable("No working microphone input was found.")
            recognitionRequest = nil
            return
        }

        let detector = LocalVoiceActivityDetector()
        activityDetector = detector
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request, weak self] buffer, _ in
            request?.append(buffer)
            let decibels = Self.decibels(in: buffer)
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            guard let update = detector.process(decibels: decibels, duration: duration) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleVoiceActivity(update)
            }
        }
        inputTapInstalled = true

        let recognitionID = UUID()
        self.recognitionID = recognitionID
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.recognitionID == recognitionID else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.completeRecognition()
                        return
                    }
                }
                if let error, self.phase != .finishing || self.transcript.isEmpty {
                    self.stopAudioCapture()
                    self.phase = .unavailable(error.localizedDescription)
                } else if error != nil {
                    // The recognizer often closes its stream with an error after
                    // endAudio(); a non-empty transcript is still usable.
                    self.completeRecognition()
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            phase = .listening
        } catch {
            stopAudioCapture()
            phase = .unavailable(error.localizedDescription)
        }
    }

    private func completeRecognition() {
        let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopAudioCapture()
        phase = .idle
        if !finalText.isEmpty {
            completedTranscript = CompletedTranscript(text: finalText)
        }
    }

    private func cancelActiveRecognition() {
        recognitionID = nil
        activityDetector = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()
    }

    private func stopAudioCapture() {
        recognitionID = nil
        activityDetector = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioLevel = 0
    }

    private func handleVoiceActivity(_ update: LocalVoiceActivityDetector.Update) {
        guard phase == .listening else { return }
        audioLevel = update.level
        switch update.endpoint {
        case .silence, .maximumDuration:
            finishRecording()
        case .noSpeech:
            cancel()
            notice = Notice(message: "I didn’t hear a command. Tap the microphone to try again.")
        case nil:
            break
        }
    }

    nonisolated private static func decibels(in buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return -80
        }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let value = samples[index]
            sum += value * value
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return 20 * log10(Double(max(rms, 0.000_01)))
    }

    private func removeInputTap() {
        guard inputTapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    private static var hasPrivacyDescriptions: Bool {
        let microphone = Bundle.main.object(
            forInfoDictionaryKey: "NSMicrophoneUsageDescription"
        ) as? String
        let speech = Bundle.main.object(
            forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription"
        ) as? String
        return microphone?.isEmpty == false && speech?.isEmpty == false
    }

    private static func speechAuthorizationMessage(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> String {
        switch status {
        case .denied:
            "Speech recognition access is off. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .restricted:
            "Speech recognition is restricted on this Mac."
        case .notDetermined:
            "Speech recognition permission wasn't granted."
        case .authorized:
            ""
        @unknown default:
            "Speech recognition permission is unavailable."
        }
    }
}

/// Uses installed macOS voices; no generated text or audio leaves the Mac.
struct LocalSpeechVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: String

    var displayName: String {
        quality == "Standard" ? "\(name) · \(language)" : "\(name) · \(quality)"
    }
}

@MainActor
final class LocalSpeechFeedback: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let voiceIdentifierKey = "foundry.voice.identifier"
    static let automaticVoiceIdentifier = ""

    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, onFinish: (() -> Void)? = nil) {
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
        completion = onFinish
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolvedVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.92
        synthesizer.speak(utterance)
    }

    func stop() {
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            let completion = self?.completion
            self?.completion = nil
            completion?()
        }
    }

    static let installedVoiceOptions: [LocalSpeechVoiceOption] = {
        let languageCode = Locale.current.language.languageCode?.identifier
            ?? Locale.current.identifier.prefix(2).lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language.lowercased().hasPrefix(languageCode)
                    && $0.quality != .default
            }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue {
                    return $0.quality.rawValue > $1.quality.rawValue
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map {
                LocalSpeechVoiceOption(
                    id: $0.identifier,
                    name: $0.name,
                    language: Locale.current.localizedString(forIdentifier: $0.language)
                        ?? $0.language,
                    quality: qualityName($0.quality)
                )
            }
    }()

    private static func resolvedVoice() -> AVSpeechSynthesisVoice? {
        let savedIdentifier = UserDefaults.standard.string(forKey: voiceIdentifierKey) ?? ""
        if !savedIdentifier.isEmpty,
           let saved = AVSpeechSynthesisVoice(identifier: savedIdentifier) {
            return saved
        }

        let preferredIDs = Set(installedVoiceOptions.map(\.id))
        if let premium = AVSpeechSynthesisVoice.speechVoices()
            .filter({ preferredIDs.contains($0.identifier) })
            .max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
            return premium
        }
        // Asking AVFoundation for the locale default avoids accidentally
        // choosing a novelty voice when no enhanced download is installed.
        return AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: "Standard"
        case .enhanced: "Enhanced"
        case .premium: "Premium"
        @unknown default: "Standard"
        }
    }
}

import AVFoundation
import Speech
import os

enum VoiceCommand {
    case next
    case previous
    case repeatStep
}

@MainActor
final class VoiceCommandService: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var detectedCommand: VoiceCommand?
    @Published var detectedQuery: String?
    @Published var errorMessage: String?
    @Published var isRestarting = false
    @Published var isUserPaused = false

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastCommand: VoiceCommand?
    private var lastCommandDetectedAt: TimeInterval = 0
    private var suppressCommands = false
    private var sessionId: Int = 0
    private var ttsActive = false
    private let logger = Logger(subsystem: "com.example.CookingAssistant", category: "voice")
    private var lastSpeechTime: TimeInterval = 0
    private var lastNonEmptyTranscript = ""
    private var lastPartialTranscript = ""
    private var lastCommandTime: TimeInterval = 0
    private var lastNonCommandTime: TimeInterval = 0
    private let inactivityTimeout: TimeInterval = 5
    private let commandDebounce: TimeInterval = 0.75
    private var shouldStopOnFinal = false
    private var stopReason: String?
    private let autoRestartEnabled = true
    private var sessionStartTime: TimeInterval = 0
    private let autoRestartReasons: Set<String> = ["inactivity_timeout", "final", "recognition_error"]
    // #region agent log
    private let debugLogPath = "/Users/mareal/cooking-assistant-ios/.cursor/debug.log"

    private func debugLog(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any]
    ) {
        let payload: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Date().timeIntervalSince1970 * 1000,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }

        if let handle = FileHandle(forWritingAtPath: debugLogPath) {
            handle.seekToEndOfFile()
            handle.write(json)
            handle.write(Data("\n".utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: debugLogPath, contents: json + Data("\n".utf8))
            postDebug(json)
        }
    }
    
    private func postDebug(_ json: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:7242/ingest/116df77c-a424-451d-a9cd-5b90048690e6")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = json
        URLSession.shared.dataTask(with: request).resume()
    }
    // #endregion

    func startListening() {
        if ttsActive {
            return
        }
        if isUserPaused {
            return
        }
        if isListening {
            return
        }
        resetSessionState()
        errorMessage = nil

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized:
                    self.beginSession()
                case .denied:
                    self.errorMessage = "Speech recognition permission denied."
                case .restricted:
                    self.errorMessage = "Speech recognition is restricted on this device."
                case .notDetermined:
                    self.errorMessage = "Speech recognition permission not determined."
                @unknown default:
                    self.errorMessage = "Speech recognition permission unavailable."
                }
            }
        }
    }

    func stopListening(force: Bool = true, reason: String? = nil) {
        stopReason = reason
        isUserPaused = (reason == "user_pause")
        if reason == "inactivity_timeout" {
            suppressCommands = true
        }
        if force {
            recognitionTask?.cancel()
            recognitionTask = nil
        } else {
            shouldStopOnFinal = true
        }
        stopAudioEngine()
        isListening = false
        if force {
            shouldStopOnFinal = false
        }
        logger.info("Voice listening stopped")
        debugLog(
            hypothesisId: "I",
            location: "VoiceCommandService.stopListening",
            message: "stop_listening",
            data: ["force": force, "reason": reason ?? "unknown"]
        )

        autoRestartIfNeeded(reason: reason)
    }

    func clearDetectedCommand() {
        detectedCommand = nil
    }

    func clearDetectedQuery() {
        detectedQuery = nil
    }

    func setTtsActive(_ active: Bool) {
        ttsActive = active
        if active {
            stopListening(force: true, reason: "tts")
        }
    }

    func resumeAfterUserPause() {
        isUserPaused = false
        startListening()
    }

    private func beginSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest?.shouldReportPartialResults = true

            guard let recognitionRequest else {
                errorMessage = "Unable to start speech request."
                return
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self else { return }
                recognitionRequest.append(buffer)

                let now = Date().timeIntervalSince1970
                if lastSpeechTime > 0, now - lastSpeechTime >= inactivityTimeout {
                    Task { @MainActor in
                        let shouldSendQuery = self.lastNonCommandTime > self.lastCommandTime
                        self.debugLog(
                            hypothesisId: "H",
                            location: "VoiceCommandService.audioTap",
                            message: "inactivity_timeout",
                            data: [
                                "seconds": now - self.lastSpeechTime,
                                "uptime": now - self.sessionStartTime,
                                "hasTranscript": !self.lastNonEmptyTranscript.isEmpty,
                                "lastCommandAge": self.lastCommandTime == 0 ? -1 : (now - self.lastCommandTime),
                                "lastNonCommandAge": self.lastNonCommandTime == 0 ? -1 : (now - self.lastNonCommandTime),
                                "shouldSendQuery": shouldSendQuery,
                            ]
                        )
                        if shouldSendQuery {
                            let fallback = self.lastNonEmptyTranscript.isEmpty
                                ? self.lastPartialTranscript
                                : self.lastNonEmptyTranscript
                            self.lastNonEmptyTranscript = ""
                            self.lastPartialTranscript = ""
                            self.handleTranscript(fallback, isFinal: true)
                        }
                        self.lastCommand = nil
                        self.lastCommandTime = 0
                        self.isRestarting = true
                        self.stopListening(force: false, reason: "inactivity_timeout")
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            isRestarting = false
            logger.info("Voice listening started")

            let activeSessionId = self.sessionId
            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    guard activeSessionId == self.sessionId else {
                        return
                    }

                    if let result {
                        self.handleRecognitionResult(result)
                    }

                    if let error {
                        self.handleRecognitionError(error)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Voice session error: \(error.localizedDescription, privacy: .public)")
            stopListening()
        }
    }

    private func handleTranscript(_ transcript: String, isFinal: Bool) {
        if suppressCommands {
            if isFinal {
                lastCommand = nil
            }
            return
        }
        let lowercased = transcript.lowercased()
        let isQuestion = isQuestionLike(lowercased)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandAllowed = Self.isLikelyCommand(transcript) && !isQuestion
        let command = commandAllowed ? Self.detectCommand(in: lowercased) : nil

        if let command {
            handleCommand(command, isFinal: isFinal, transcript: transcript)
        }

        if isFinal {
            if trimmed.isEmpty {
                return
            }

            handleQueryIfNeeded(command: command, isQuestion: isQuestion, transcript: transcript)
        }

        if isFinal {
            lastCommand = nil
        }
    }

    func processLastPartialAfterTimeout() {
        let trimmed = lastPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        handleTranscript(trimmed, isFinal: true)
    }

    private func isQuestionLike(_ transcript: String) -> Bool {
        if transcript.contains("?") {
            return true
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let starters = [
            "how", "what", "when", "where", "why", "who",
            "is", "are", "do", "does", "did",
            "can", "could", "should", "would", "will",
            "may", "might",
        ]

        if let first = trimmed.split(separator: " ").first,
           starters.contains(String(first)) {
            return true
        }

        let containsCues = [
            "how many",
            "how much",
            "what is",
            "what's",
            "convert",
            "need to",
            "do i",
            "does it",
        ]

        return containsCues.contains { trimmed.contains($0) }
    }

    private static func isLikelyCommand(_ transcript: String) -> Bool {
        let lowercased = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowercased.isEmpty {
            return false
        }
        let tokens = lowercased.split(separator: " ").map(String.init)
        let first = tokens.first ?? ""
        let commandWords = ["next", "previous", "back", "repeat"]
        let allowedFiller = ["step", "please", "now", "the", "a", "an"]
        if commandWords.contains(first) {
            let rest = tokens.dropFirst()
            return rest.allSatisfy { allowedFiller.contains($0) || commandWords.contains($0) }
        }
        if tokens.count >= 2, tokens[0] == "go", commandWords.contains(tokens[1]) {
            let rest = tokens.dropFirst(2)
            return rest.allSatisfy { allowedFiller.contains($0) || commandWords.contains($0) }
        }
        return false
    }

    private static func lastRangeIndex(of needle: String, in haystack: String) -> Int {
        guard let range = haystack.range(of: needle, options: [.caseInsensitive, .backwards]) else {
            return -1
        }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    }

    private static func detectCommand(in lowercased: String) -> VoiceCommand? {
        let matches: [(VoiceCommand, Int)] = [
            (.next, lastRangeIndex(of: "next", in: lowercased)),
            (.previous, lastRangeIndex(of: "previous", in: lowercased)),
            (.previous, lastRangeIndex(of: "back", in: lowercased)),
            (.repeatStep, lastRangeIndex(of: "repeat", in: lowercased)),
        ]
        let best = matches.filter { $0.1 >= 0 }.max { $0.1 < $1.1 }
        return best?.0
    }

    private func resetSessionState() {
        sessionStartTime = Date().timeIntervalSince1970
        sessionId += 1
        shouldStopOnFinal = false
        stopReason = nil
        lastSpeechTime = 0
        lastNonEmptyTranscript = ""
        lastNonCommandTime = 0
        lastCommand = nil
        lastCommandDetectedAt = 0
        suppressCommands = false
        isUserPaused = false
    }

    private func stopAudioEngine() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    private func autoRestartIfNeeded(reason: String?) {
        guard autoRestartEnabled, reason != "user_pause" else { return }
        guard let reason, autoRestartReasons.contains(reason) else { return }
        guard !ttsActive, reason != "tts" else { return }
        Task { @MainActor in
            self.isRestarting = true
            if reason == "recognition_error" {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self.startListening()
        }
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult) {
        if ttsActive || isUserPaused {
            return
        }
        let phrase = result.bestTranscription.formattedString
        transcript = phrase
        updateLastSpeech(with: phrase)
        handleTranscript(phrase, isFinal: result.isFinal)

        if shouldStopOnFinal, result.isFinal {
            stopListening(force: true, reason: stopReason ?? "final")
        }
    }

    private func handleRecognitionError(_ error: Error) {
        if ttsActive || stopReason == "tts" { return }
        if isUserPaused || stopReason == "user_pause" { return }
        debugLog(
            hypothesisId: "D",
            location: "VoiceCommandService.recognitionTask",
            message: "recognition_error",
            data: ["error": error.localizedDescription]
        )
        errorMessage = error.localizedDescription
        logger.error("Voice error: \(error.localizedDescription, privacy: .public)")
        stopListening(force: true, reason: "recognition_error")
    }

    private func updateLastSpeech(with phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        lastPartialTranscript = phrase
        if Self.isLikelyCommand(phrase) {
            lastCommandTime = now
        } else {
            lastNonCommandTime = now
            lastNonEmptyTranscript = phrase
        }
        lastSpeechTime = now
    }

    private func handleCommand(_ command: VoiceCommand, isFinal: Bool, transcript: String) {
        let now = Date().timeIntervalSince1970
        let isRepeat = command == lastCommand
        let withinDebounce = now - lastCommandDetectedAt < commandDebounce
        if isRepeat && withinDebounce {
            debugLog(
                hypothesisId: "Q",
                location: "VoiceCommandService.handleTranscript",
                message: "command_suppressed_debounce",
                data: ["command": String(describing: command)]
            )
            return
        }
        debugLog(
            hypothesisId: "Q",
            location: "VoiceCommandService.handleTranscript",
            message: "command_detected",
            data: ["command": String(describing: command), "isFinal": isFinal, "length": transcript.count]
        )
        lastCommandTime = now
        lastCommandDetectedAt = now
        lastNonEmptyTranscript = ""
        lastPartialTranscript = ""
        lastNonCommandTime = 0
        detectedCommand = command
        lastCommand = command
        logger.info("Detected voice command: \(String(describing: command), privacy: .public)")
    }

    private func handleQueryIfNeeded(command: VoiceCommand?, isQuestion: Bool, transcript: String) {
        guard command == nil else { return }
        guard isQuestion else { return }
        debugLog(
            hypothesisId: "B",
            location: "VoiceCommandService.handleTranscript",
            message: "query_detected",
            data: ["length": transcript.count]
        )
        detectedQuery = transcript
    }
}

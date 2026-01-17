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
    private var audioBufferCount = 0
    private var lastAudioLogTime: TimeInterval = 0
    private var lastResultLogTime: TimeInterval = 0
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
            debugLog(
                hypothesisId: "K",
                location: "VoiceCommandService.startListening",
                message: "start_ignored_tts_active",
                data: [:]
            )
            return
        }
        if isUserPaused {
            debugLog(
                hypothesisId: "K",
                location: "VoiceCommandService.startListening",
                message: "start_ignored_user_paused",
                data: [:]
            )
            return
        }
        if isListening {
            debugLog(
                hypothesisId: "K",
                location: "VoiceCommandService.startListening",
                message: "start_ignored_already_listening",
                data: ["isListening": isListening]
            )
            return
        }
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
        debugLog(
            hypothesisId: "K",
            location: "VoiceCommandService.startListening",
            message: "reset_state_for_followup",
            data: [
                "shouldStopOnFinal": shouldStopOnFinal,
                "lastSpeechTime": lastSpeechTime,
                "lastNonEmptyTranscriptLength": lastNonEmptyTranscript.count,
            ]
        )
        debugLog(
            hypothesisId: "K",
            location: "VoiceCommandService.startListening",
            message: "start_attempt",
            data: [
                "isListening": isListening,
                "audioEngineRunning": audioEngine.isRunning,
                "hasRecognitionTask": recognitionTask != nil,
                "hasRecognitionRequest": recognitionRequest != nil,
                "shouldStopOnFinal": shouldStopOnFinal,
            ]
        )
        errorMessage = nil
        debugLog(
            hypothesisId: "E",
            location: "VoiceCommandService.startListening",
            message: "start_listening",
            data: ["isListening": isListening]
        )

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.debugLog(
                    hypothesisId: "E",
                    location: "VoiceCommandService.startListening",
                    message: "auth_status",
                    data: ["status": String(describing: status)]
                )
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
        if reason == "user_pause" {
            isUserPaused = true
        } else {
            isUserPaused = false
        }
        if reason == "inactivity_timeout" {
            suppressCommands = true
        }
        if force {
            recognitionTask?.cancel()
            recognitionTask = nil
        } else {
            shouldStopOnFinal = true
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

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
        debugLog(
            hypothesisId: "K",
            location: "VoiceCommandService.stopListening",
            message: "stop_state",
            data: [
                "audioEngineRunning": audioEngine.isRunning,
                "hasRecognitionTask": recognitionTask != nil,
                "hasRecognitionRequest": recognitionRequest != nil,
                "shouldStopOnFinal": shouldStopOnFinal,
            ]
        )

        if autoRestartEnabled, reason != "user_pause" {
            debugLog(
                hypothesisId: "L",
                location: "VoiceCommandService.stopListening",
                message: "auto_restart_requested",
                data: ["reason": reason ?? "unknown"]
            )
            if let reason, autoRestartReasons.contains(reason) {
                Task { @MainActor in
                    if self.ttsActive || reason == "tts" {
                        self.debugLog(
                            hypothesisId: "L",
                            location: "VoiceCommandService.stopListening",
                            message: "auto_restart_suppressed_tts",
                            data: ["reason": reason]
                        )
                        return
                    }
                    self.isRestarting = true
                    if reason == "recognition_error" {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                    self.startListening()
                }
            }
        }
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
            debugLog(
                hypothesisId: "K",
                location: "VoiceCommandService.beginSession",
                message: "begin_session_enter",
                data: [
                    "audioEngineRunning": audioEngine.isRunning,
                    "shouldStopOnFinal": shouldStopOnFinal,
                ]
            )
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            debugLog(
                hypothesisId: "F",
                location: "VoiceCommandService.beginSession",
                message: "audio_session_active",
                data: [
                    "routeInputs": session.currentRoute.inputs.map { $0.portType.rawValue },
                    "routeOutputs": session.currentRoute.outputs.map { $0.portType.rawValue },
                ]
            )

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest?.shouldReportPartialResults = true

            guard let recognitionRequest else {
                errorMessage = "Unable to start speech request."
                debugLog(
                    hypothesisId: "F",
                    location: "VoiceCommandService.beginSession",
                    message: "missing_recognition_request",
                    data: [:]
                )
                return
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            debugLog(
                hypothesisId: "F",
                location: "VoiceCommandService.beginSession",
                message: "input_format",
                data: [
                    "sampleRate": recordingFormat.sampleRate,
                    "channels": recordingFormat.channelCount,
                ]
            )
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self else { return }
                recognitionRequest.append(buffer)
                audioBufferCount += 1

                let now = Date().timeIntervalSince1970
                if now - lastAudioLogTime > 1.0 {
                    lastAudioLogTime = now
                    let rms = Self.rmsAmplitude(buffer: buffer)
                    debugLog(
                        hypothesisId: "F",
                        location: "VoiceCommandService.audioTap",
                        message: "audio_buffer",
                        data: [
                            "frames": buffer.frameLength,
                            "rms": rms,
                            "buffersSeen": audioBufferCount,
                        ]
                    )
                }

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
                        self.isRestarting = true
                        self.stopListening(force: false, reason: "inactivity_timeout")
                        self.debugLog(
                            hypothesisId: "H",
                            location: "VoiceCommandService.audioTap",
                            message: "restart_after_timeout",
                            data: ["sentTranscript": shouldSendQuery && !self.lastNonEmptyTranscript.isEmpty]
                        )
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            isRestarting = false
            logger.info("Voice listening started")
            debugLog(
                hypothesisId: "F",
                location: "VoiceCommandService.beginSession",
                message: "audio_engine_started",
                data: ["isRunning": audioEngine.isRunning]
            )

            let activeSessionId = self.sessionId
            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    guard activeSessionId == self.sessionId else {
                        self.debugLog(
                            hypothesisId: "D",
                            location: "VoiceCommandService.recognitionTask",
                            message: "stale_session_result",
                            data: ["sessionId": activeSessionId, "current": self.sessionId]
                        )
                        return
                    }

                    if let result {
                        if self.ttsActive {
                            self.debugLog(
                                hypothesisId: "D",
                                location: "VoiceCommandService.recognitionTask",
                                message: "result_suppressed_tts",
                                data: ["isFinal": result.isFinal]
                            )
                            return
                        }
                        if self.isUserPaused {
                            self.debugLog(
                                hypothesisId: "D",
                                location: "VoiceCommandService.recognitionTask",
                                message: "result_suppressed_user_paused",
                                data: ["isFinal": result.isFinal]
                            )
                            return
                        }
                        let phrase = result.bestTranscription.formattedString
                        self.transcript = phrase
                        let now = Date().timeIntervalSince1970
                        if !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.lastPartialTranscript = phrase
                            if Self.isLikelyCommand(phrase) {
                                self.lastCommandTime = now
                                self.debugLog(
                                    hypothesisId: "S",
                                    location: "VoiceCommandService.recognitionTask",
                                    message: "command_like_transcript",
                                    data: ["length": phrase.count]
                                )
                            } else {
                                self.lastNonCommandTime = now
                                self.lastSpeechTime = now
                                self.lastNonEmptyTranscript = phrase
                            }
                            self.lastSpeechTime = now
                        }
                        if now - self.lastResultLogTime > 0.5 {
                            self.lastResultLogTime = now
                            self.debugLog(
                                hypothesisId: "G",
                                location: "VoiceCommandService.recognitionTask",
                                message: "speech_result",
                                data: [
                                    "isFinal": result.isFinal,
                                    "length": phrase.count,
                                ]
                            )
                        }
                        self.handleTranscript(phrase, isFinal: result.isFinal)

                        if self.shouldStopOnFinal, result.isFinal {
                            self.debugLog(
                                hypothesisId: "I",
                                location: "VoiceCommandService.recognitionTask",
                                message: "final_received_stop",
                                data: ["reason": self.stopReason ?? "inactivity_timeout"]
                            )
                            self.stopListening(force: true, reason: self.stopReason ?? "final")
                        }
                    }

                    if let error {
                        if self.ttsActive || self.stopReason == "tts" {
                            self.debugLog(
                                hypothesisId: "D",
                                location: "VoiceCommandService.recognitionTask",
                                message: "error_suppressed_tts",
                                data: ["error": error.localizedDescription]
                            )
                            return
                        }
                        if self.isUserPaused || self.stopReason == "user_pause" {
                            self.debugLog(
                                hypothesisId: "D",
                                location: "VoiceCommandService.recognitionTask",
                                message: "error_suppressed_user_paused",
                                data: ["error": error.localizedDescription]
                            )
                            return
                        }
                        self.debugLog(
                            hypothesisId: "D",
                            location: "VoiceCommandService.recognitionTask",
                            message: "recognition_error",
                            data: [
                                "error": error.localizedDescription,
                                "uptime": Date().timeIntervalSince1970 - self.sessionStartTime,
                            ]
                        )
                        self.errorMessage = error.localizedDescription
                        self.logger.error("Voice error: \(error.localizedDescription, privacy: .public)")
                        self.stopListening(force: true, reason: "recognition_error")
                    }
                }
            }
            debugLog(
                hypothesisId: "F",
                location: "VoiceCommandService.beginSession",
                message: "recognition_task_started",
                data: ["recognizerAvailable": speechRecognizer?.isAvailable ?? false]
            )
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Voice session error: \(error.localizedDescription, privacy: .public)")
            debugLog(
                hypothesisId: "F",
                location: "VoiceCommandService.beginSession",
                message: "begin_session_error",
                data: ["error": error.localizedDescription]
            )
            stopListening()
        }
    }

    private static func rmsAmplitude(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?.pointee else {
            return 0
        }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        return sqrt(sum / Float(frameLength))
    }

    private func handleTranscript(_ transcript: String, isFinal: Bool) {
        if suppressCommands {
            debugLog(
                hypothesisId: "Q",
                location: "VoiceCommandService.handleTranscript",
                message: "suppressed_after_stop",
                data: ["isFinal": isFinal, "length": transcript.count]
            )
            if isFinal {
                lastCommand = nil
            }
            return
        }
        let lowercased = transcript.lowercased()
        let command: VoiceCommand?
        let isQuestion = isQuestionLike(lowercased)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandAllowed = Self.isLikelyCommand(transcript) && !isQuestion
        debugLog(
            hypothesisId: "Q",
            location: "VoiceCommandService.handleTranscript",
            message: "transcript_received",
            data: [
                "isFinal": isFinal,
                "length": transcript.count,
                "containsNext": lowercased.contains("next"),
                "containsPrev": lowercased.contains("previous") || lowercased.contains("back"),
                "containsRepeat": lowercased.contains("repeat"),
            ]
        )

        if commandAllowed && lowercased.contains("next") {
            command = .next
        } else if commandAllowed && (lowercased.contains("previous") || lowercased.contains("back")) {
            command = .previous
        } else if commandAllowed && lowercased.contains("repeat") {
            command = .repeatStep
        } else {
            command = nil
        }

        if let command {
            let now = Date().timeIntervalSince1970
            let isRepeat = command == lastCommand
            let withinDebounce = now - lastCommandDetectedAt < commandDebounce
            if isRepeat && withinDebounce {
                debugLog(
                    hypothesisId: "Q",
                    location: "VoiceCommandService.handleTranscript",
                    message: "command_suppressed_debounce",
                    data: [
                        "command": String(describing: command),
                        "delta": now - lastCommandDetectedAt,
                    ]
                )
            } else {
            debugLog(
                hypothesisId: "Q",
                location: "VoiceCommandService.handleTranscript",
                message: "command_detected",
                data: [
                    "command": String(describing: command),
                    "isFinal": isFinal,
                    "length": transcript.count,
                ]
            )
            lastCommandTime = now
            lastCommandDetectedAt = now
            lastNonEmptyTranscript = ""
            lastPartialTranscript = ""
            lastNonCommandTime = 0
            detectedCommand = command
            lastCommand = command
            logger.info("Detected voice command: \(String(describing: command), privacy: .public)")
            debugLog(
                hypothesisId: "R",
                location: "VoiceCommandService.handleTranscript",
                message: "command_applied",
                data: [
                    "command": String(describing: command),
                    "clearedTranscript": true,
                ]
            )
            }
        }

        if isFinal {
            debugLog(
                hypothesisId: "B",
                location: "VoiceCommandService.handleTranscript",
                message: "final_transcript",
                data: [
                    "length": transcript.count,
                    "isQuestion": isQuestion,
                    "hasCommand": command != nil,
                ]
            )
            logger.info("Final transcript: \(transcript, privacy: .private(mask: .hash))")
            logger.info("Is question: \(isQuestion, privacy: .public)")
            logger.info("Transcript (raw): \(transcript, privacy: .private)")

            if trimmed.isEmpty {
                debugLog(
                    hypothesisId: "B",
                    location: "VoiceCommandService.handleTranscript",
                    message: "skip_empty_transcript",
                    data: [:]
                )
                return
            }

            if command == nil {
                debugLog(
                    hypothesisId: "B",
                    location: "VoiceCommandService.handleTranscript",
                    message: "detected_query_no_command",
                    data: ["length": transcript.count, "isQuestion": isQuestion]
                )
                detectedQuery = transcript
                logger.info("Detected voice query for command = nil: \(transcript, privacy: .private(mask: .hash))")
            } else if isQuestion {
                debugLog(
                    hypothesisId: "B",
                    location: "VoiceCommandService.handleTranscript",
                    message: "detected_query_question",
                    data: ["length": transcript.count, "isQuestion": isQuestion]
                )
                detectedQuery = transcript
                logger.info("Detected voice query (question) for isQuestion = true: \(transcript, privacy: .private(mask: .hash))")
            }
        }

        if isFinal {
            lastCommand = nil
        }
    }

    func processLastPartialAfterTimeout() {
        let trimmed = lastPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog(
            hypothesisId: "T",
            location: "VoiceCommandService.processLastPartialAfterTimeout",
            message: "process_partial",
            data: ["length": trimmed.count]
        )
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

    private static func containsCommandKeyword(_ transcript: String) -> Bool {
        let lowercased = transcript.lowercased()
        return lowercased.contains("next")
            || lowercased.contains("previous")
            || lowercased.contains("back")
            || lowercased.contains("repeat")
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
            return rest.allSatisfy { allowedFiller.contains($0) }
        }
        if tokens.count >= 2, tokens[0] == "go", commandWords.contains(tokens[1]) {
            let rest = tokens.dropFirst(2)
            return rest.allSatisfy { allowedFiller.contains($0) }
        }
        return false
    }
}

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

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastCommand: VoiceCommand?
    private let logger = Logger(subsystem: "com.example.CookingAssistant", category: "voice")
    private var audioBufferCount = 0
    private var lastAudioLogTime: TimeInterval = 0
    private var lastResultLogTime: TimeInterval = 0
    private var lastSpeechTime: TimeInterval = 0
    private var lastNonEmptyTranscript = ""
    private let inactivityTimeout: TimeInterval = 5
    private var shouldStopOnFinal = false
    private var stopReason: String?
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
        }
    }
    // #endregion

    func startListening() {
        if isListening {
            debugLog(
                hypothesisId: "K",
                location: "VoiceCommandService.startListening",
                message: "start_ignored_already_listening",
                data: ["isListening": isListening]
            )
            return
        }
        shouldStopOnFinal = false
        stopReason = nil
        lastSpeechTime = 0
        lastNonEmptyTranscript = ""
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
    }

    func clearDetectedCommand() {
        detectedCommand = nil
    }

    func clearDetectedQuery() {
        detectedQuery = nil
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
                        self.debugLog(
                            hypothesisId: "H",
                            location: "VoiceCommandService.audioTap",
                            message: "inactivity_timeout",
                            data: [
                                "seconds": now - self.lastSpeechTime,
                                "hasTranscript": !self.lastNonEmptyTranscript.isEmpty,
                            ]
                        )
                        if !self.lastNonEmptyTranscript.isEmpty {
                            self.detectedQuery = self.lastNonEmptyTranscript
                        }
                        self.stopListening(force: false, reason: "inactivity_timeout")
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            logger.info("Voice listening started")
            debugLog(
                hypothesisId: "F",
                location: "VoiceCommandService.beginSession",
                message: "audio_engine_started",
                data: ["isRunning": audioEngine.isRunning]
            )

            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }

                    if let result {
                        let phrase = result.bestTranscription.formattedString
                        self.transcript = phrase
                        let now = Date().timeIntervalSince1970
                        if !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.lastSpeechTime = now
                            self.lastNonEmptyTranscript = phrase
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
                        self.debugLog(
                            hypothesisId: "D",
                            location: "VoiceCommandService.recognitionTask",
                            message: "recognition_error",
                            data: ["error": error.localizedDescription]
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
        let lowercased = transcript.lowercased()
        let command: VoiceCommand?
        let isQuestion = isQuestionLike(lowercased)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if lowercased.contains("next") {
            command = .next
        } else if lowercased.contains("previous") || lowercased.contains("back") {
            command = .previous
        } else if lowercased.contains("repeat") {
            command = .repeatStep
        } else {
            command = nil
        }

        if let command, command != lastCommand {
            detectedCommand = command
            lastCommand = command
            logger.info("Detected voice command: \(String(describing: command), privacy: .public)")
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
                    data: ["length": transcript.count]
                )
                detectedQuery = transcript
                logger.info("Detected voice query for command = nil: \(transcript, privacy: .private(mask: .hash))")
            } else if isQuestion {
                debugLog(
                    hypothesisId: "B",
                    location: "VoiceCommandService.handleTranscript",
                    message: "detected_query_question",
                    data: ["length": transcript.count]
                )
                detectedQuery = transcript
                logger.info("Detected voice query (question) for isQuestion = true: \(transcript, privacy: .private(mask: .hash))")
            }
        }

        if isFinal {
            lastCommand = nil
        }
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
}

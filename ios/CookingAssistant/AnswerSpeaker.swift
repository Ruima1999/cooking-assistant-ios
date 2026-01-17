import AVFoundation
import os

final class AnswerSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.example.CookingAssistant", category: "speech")
    // #region agent log
    private let debugLogPath = "/Users/mareal/cooking-assistant-ios/.cursor/debug.log"
    // #endregion
    var onSpeakStart: (() -> Void)?
    var onSpeakFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredFemaleVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        logger.info("Speaking answer")
        debugLog(
            hypothesisId: "M",
            location: "AnswerSpeaker.speak",
            message: "tts_start",
            data: ["length": text.count]
        )
        synthesizer.speak(utterance)
    }

    private func preferredFemaleVoice() -> AVSpeechSynthesisVoice? {
        let preferredNames = ["Samantha", "Karen", "Moira"]
        let voices = AVSpeechSynthesisVoice.speechVoices()

        if let match = voices.first(where: { preferredNames.contains($0.name) }) {
            return match
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        debugLog(
            hypothesisId: "M",
            location: "AnswerSpeaker.didStart",
            message: "tts_did_start",
            data: [:]
        )
        onSpeakStart?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        debugLog(
            hypothesisId: "M",
            location: "AnswerSpeaker.didFinish",
            message: "tts_did_finish",
            data: [:]
        )
        onSpeakFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        debugLog(
            hypothesisId: "M",
            location: "AnswerSpeaker.didCancel",
            message: "tts_did_cancel",
            data: [:]
        )
        onSpeakFinish?()
    }

    // #region agent log
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
}

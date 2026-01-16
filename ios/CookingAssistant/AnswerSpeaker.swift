import AVFoundation
import os

final class AnswerSpeaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.example.CookingAssistant", category: "speech")

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
}

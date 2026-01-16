import Foundation
import os

final class QAService {
    private let session = URLSession.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: "com.example.CookingAssistant", category: "qa")
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

    func answer(for question: String, context: String?) async throws -> String {
        debugLog(
            hypothesisId: "A",
            location: "QAService.answer",
            message: "qa_enter",
            data: ["questionLength": question.count, "hasContext": context != nil]
        )
        guard let baseURL = AppConfig.workerBaseURL else {
            logger.error("Missing WORKER_BASE_URL")
            debugLog(
                hypothesisId: "A",
                location: "QAService.answer",
                message: "missing_base_url",
                data: ["baseURLSet": false]
            )
            throw QAError.missingBaseURL
        }
        debugLog(
            hypothesisId: "A",
            location: "QAService.answer",
            message: "base_url_set",
            data: ["baseURLSet": true]
        )

        var request = URLRequest(url: baseURL.appending(path: "qa"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let payload = QAPayload(question: question, context: context)
        request.httpBody = try encoder.encode(payload)
        logger.info("Sending Q&A request")
        debugLog(
            hypothesisId: "C",
            location: "QAService.answer",
            message: "request_sent",
            data: ["baseURL": baseURL.absoluteString]
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid HTTP response")
            debugLog(
                hypothesisId: "C",
                location: "QAService.answer",
                message: "invalid_http_response",
                data: [:]
            )
            throw QAError.invalidResponse
        }

        debugLog(
            hypothesisId: "C",
            location: "QAService.answer",
            message: "response_received",
            data: ["status": httpResponse.statusCode]
        )
        if httpResponse.statusCode >= 400 {
            let message = (try? decoder.decode(QAErrorResponse.self, from: data))?.error
            logger.error("Q&A error status \(httpResponse.statusCode, privacy: .public)")
            debugLog(
                hypothesisId: "C",
                location: "QAService.answer",
                message: "qa_error",
                data: ["status": httpResponse.statusCode]
            )
            throw QAError.server(message ?? "Unable to answer the question.")
        }

        let answer = try decoder.decode(QAResponse.self, from: data)
        logger.info("Q&A answered successfully")
        return answer.answer
    }
}

struct QAPayload: Codable {
    let question: String
    let context: String?
}

struct QAResponse: Codable {
    let answer: String
}

struct QAErrorResponse: Codable {
    let error: String
}

enum QAError: LocalizedError {
    case missingBaseURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Missing worker base URL. Set WORKER_BASE_URL to enable Q&A."
        case .invalidResponse:
            return "Invalid response from the Q&A service."
        case .server(let message):
            return message
        }
    }
}

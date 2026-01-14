import Foundation

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var session: SupabaseSession?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let authService = SupabaseAuthService()

    var isAuthenticated: Bool {
        session != nil
    }

    func signUp(email: String, password: String) async {
        await runAuthTask {
            self.session = try await self.authService.signUp(email: email, password: password)
        }
    }

    func signIn(email: String, password: String) async {
        await runAuthTask {
            self.session = try await self.authService.signIn(email: email, password: password)
        }
    }

    private func runAuthTask(_ operation: @escaping () async throws -> Void) async {
        errorMessage = nil
        isLoading = true
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct SupabaseSession: Codable {
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?
    let user: SupabaseUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case user
    }
}

struct SupabaseUser: Codable {
    let id: String
    let email: String?
}

final class SupabaseAuthService {
    private let baseURL = AppConfig.supabaseURL
    private let anonKey = AppConfig.supabaseAnonKey

    func signUp(email: String, password: String) async throws -> SupabaseSession {
        try await requestAuth(
            path: "/auth/v1/signup",
            body: ["email": email, "password": password]
        )
    }

    func signIn(email: String, password: String) async throws -> SupabaseSession {
        try await requestAuth(
            path: "/auth/v1/token?grant_type=password",
            body: ["email": email, "password": password]
        )
    }

    private func requestAuth(path: String, body: [String: String]) async throws -> SupabaseSession {
        guard anonKey != "SUPABASE_ANON_KEY" else {
            throw AuthError.missingAnonKey
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let message = (try? JSONDecoder().decode(SupabaseError.self, from: data))?.message
            throw AuthError.server(message ?? "Authentication failed.")
        }

        return try JSONDecoder().decode(SupabaseSession.self, from: data)
    }
}

enum AuthError: LocalizedError {
    case missingAnonKey
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAnonKey:
            return "Missing Supabase anon key. Set AppConfig.supabaseAnonKey."
        case .invalidResponse:
            return "Invalid response from Supabase."
        case .server(let message):
            return message
        }
    }
}

struct SupabaseError: Codable {
    let message: String
}

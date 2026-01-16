import SwiftUI

struct AppConfig {
    static let supabaseURL = AppConfig.loadOptionalURL(forKey: "SUPABASE_URL")
    static let supabaseAnonKey = AppConfig.loadOptionalValue(forKey: "SUPABASE_ANON_KEY")
    static let authEnabled = AppConfig.loadBool(forKey: "AUTH_ENABLED", defaultValue: true)
    static let workerBaseURL = AppConfig.loadOptionalURL(forKey: "WORKER_BASE_URL")

    static func ingredientImageURL(for slug: String) -> URL? {
        nil
    }

    private static func loadValue(forKey key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            fatalError("Missing \(key) in Info.plist or build settings.")
        }
        return value
    }

    private static func loadURL(forKey key: String) -> URL {
        let value = loadValue(forKey: key)
        guard let url = URL(string: value) else {
            fatalError("Invalid URL for \(key): \(value)")
        }
        return url
    }

    private static func loadOptionalValue(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            debugLog(
                hypothesisId: "J",
                location: "AppConfig.loadOptionalValue",
                message: "missing_value",
                data: ["key": key]
            )
            return nil
        }
        debugLog(
            hypothesisId: "J",
            location: "AppConfig.loadOptionalValue",
            message: "loaded_value",
            data: ["key": key, "length": value.count]
        )
        return value
    }

    private static func loadOptionalURL(forKey key: String) -> URL? {
        guard let value = loadOptionalValue(forKey: key) else {
            return nil
        }
        let url = URL(string: value)
        debugLog(
            hypothesisId: "J",
            location: "AppConfig.loadOptionalURL",
            message: "parsed_url",
            data: ["key": key, "valid": url != nil]
        )
        return url
    }

    private static func loadBool(forKey key: String, defaultValue: Bool) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            debugLog(
                hypothesisId: "J",
                location: "AppConfig.loadBool",
                message: "default_value",
                data: ["key": key, "default": defaultValue]
            )
            return defaultValue
        }
        return (value as NSString).boolValue
    }

    // #region agent log
    private static let debugLogPath = "/Users/mareal/cooking-assistant-ios/.cursor/debug.log"

    private static func debugLog(
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
}

struct Recipe: Identifiable {
    let id: UUID
    let title: String
    let summary: String
    let totalTimeMinutes: Int
    let steps: [RecipeStep]

    static let sample = Recipe(
        id: UUID(),
        title: "Garlic Onion Chicken",
        summary: "Sear, simmer, and finish with aromatics.",
        totalTimeMinutes: 35,
        steps: [
            RecipeStep(
                order: 1,
                text: "Pat the chicken dry and season with salt and pepper.",
                durationSeconds: 120,
                mediaIngredientSlug: nil
            ),
            RecipeStep(
                order: 2,
                text: "Slice the onion thinly and mince the garlic.",
                durationSeconds: 180,
                mediaIngredientSlug: "onion"
            ),
            RecipeStep(
                order: 3,
                text: "Sear the chicken for 4 minutes per side until golden.",
                durationSeconds: 480,
                mediaIngredientSlug: nil
            ),
            RecipeStep(
                order: 4,
                text: "Add onion and garlic, stir for 2 minutes, then add broth.",
                durationSeconds: 300,
                mediaIngredientSlug: "garlic"
            ),
            RecipeStep(
                order: 5,
                text: "Simmer for 10 minutes, then rest for 3 minutes before serving.",
                durationSeconds: 780,
                mediaIngredientSlug: nil
            )
        ]
    )
}

struct RecipeStep: Identifiable {
    let id = UUID()
    let order: Int
    let text: String
    let durationSeconds: Int?
    let mediaIngredientSlug: String?
}

enum VoiceState {
    case idle
    case listening
    case processing
}

struct ContentView: View {
    private let recipe = Recipe.sample
    @StateObject private var authStore = AuthStore()

    var body: some View {
        NavigationStack {
            if !AppConfig.authEnabled || authStore.isAuthenticated {
                HomeView(recipe: recipe)
            } else {
                AuthView(authStore: authStore)
            }
        }
    }
}

struct HomeView: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cooking Assistant")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Hands-free, step-by-step cooking guidance.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Featured recipe")
                    .font(.headline)
                Text(recipe.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(recipe.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("Total time: \(recipe.totalTimeMinutes) min")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            NavigationLink {
                CookingModeView(recipe: recipe)
            } label: {
                Text("Start Cooking Mode")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Spacer()
        }
        .padding(24)
        .navigationTitle("Home")
    }
}

struct CookingModeView: View {
    let recipe: Recipe

    @State private var currentStepIndex = 0
    @StateObject private var voiceService = VoiceCommandService()
    private let answerSpeaker = AnswerSpeaker()
    @State private var answerText: String?
    @State private var answerError: String?
    @State private var isAnswering = false
    @State private var lastSpokenAnswer: String?
    private let qaService = QAService()

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header

                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(recipe.steps.indices, id: \.self) { index in
                            StepCard(
                                step: recipe.steps[index],
                                isCurrent: index == currentStepIndex
                            )
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
                }
                .onChange(of: currentStepIndex) { _, newValue in
                    withAnimation(.easeInOut) {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VoiceControlBar(
                    isListening: voiceService.isListening,
                    transcript: voiceService.transcript,
                    errorMessage: voiceService.errorMessage,
                    answerText: answerText,
                    isAnswering: isAnswering,
                    answerError: answerError,
                    onToggleListening: toggleListening
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            voiceService.startListening()
        }
        .onDisappear {
            voiceService.stopListening()
        }
        .onReceive(voiceService.$detectedCommand) { command in
            guard let command else { return }
            handleVoiceCommand(command)
            voiceService.clearDetectedCommand()
        }
        .onReceive(voiceService.$detectedQuery) { query in
            guard let query else { return }
            Task {
                await handleVoiceQuery(query)
                voiceService.clearDetectedQuery()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step \(currentStepIndex + 1) of \(recipe.steps.count)")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    moveToPreviousStep()
                } label: {
                    Label("Previous", systemImage: "arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(currentStepIndex == 0)

                Button {
                    moveToNextStep()
                } label: {
                    Label("Next", systemImage: "arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(currentStepIndex == recipe.steps.count - 1)
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
    }

    private func moveToPreviousStep() {
        guard currentStepIndex > 0 else { return }
        currentStepIndex -= 1
    }

    private func moveToNextStep() {
        guard currentStepIndex < recipe.steps.count - 1 else { return }
        currentStepIndex += 1
    }

    private func toggleListening() {
        if voiceService.isListening {
            voiceService.stopListening()
        } else {
            voiceService.startListening()
        }
    }

    private func handleVoiceCommand(_ command: VoiceCommand) {
        switch command {
        case .next:
            moveToNextStep()
        case .previous:
            moveToPreviousStep()
        case .repeatStep:
            withAnimation(.easeInOut) {
                // Scroll to current step to reinforce repetition.
                // The scroll view updates automatically on index change,
                // so we just re-trigger a scroll animation.
            }
        }
    }

    private func handleVoiceQuery(_ query: String) async {
        answerText = nil
        answerError = nil
        isAnswering = true
        do {
            let answer = try await qaService.answer(for: query, context: recipe.title)
            answerText = answer
            if answer != lastSpokenAnswer {
                answerSpeaker.speak(answer)
                lastSpokenAnswer = answer
            }
        } catch {
            answerError = error.localizedDescription
        }
        isAnswering = false
    }
}

struct StepCard: View {
    let step: RecipeStep
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(step.order)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .frame(width: 44, height: 44)
                    .background(isCurrent ? Color.accentColor : Color(.secondarySystemBackground))
                    .foregroundStyle(isCurrent ? .white : .primary)
                    .clipShape(Circle())

                Text(step.text)
                    .font(.title3)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let duration = step.durationSeconds {
                Text("Estimated time: \(duration / 60)m \(duration % 60)s")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let slug = step.mediaIngredientSlug {
                IngredientImageView(slug: slug)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color(.systemGray6) : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct IngredientImageView: View {
    let slug: String

    var body: some View {
        if let url = AppConfig.ingredientImageURL(for: slug) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemGray5))
                        .frame(height: 160)
                        .overlay(
                            ProgressView()
                        )
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                case .failure:
                    placeholder
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.systemGray5))
            .frame(height: 160)
            .overlay(
                Text("Image disabled")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            )
    }
}

struct VoiceControlBar: View {
    let isListening: Bool
    let transcript: String
    let errorMessage: String?
    let answerText: String?
    let isAnswering: Bool
    let answerError: String?
    let onToggleListening: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text(isListening ? "Listening for voice commands..." : "Voice paused")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !transcript.isEmpty {
                Text("Heard: \(transcript)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if isAnswering {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Answering...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let answerText {
                Text(answerText)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            } else if let answerError {
                Text(answerError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Button(action: onToggleListening) {
                HStack(spacing: 12) {
                    Image(systemName: isListening ? "waveform.circle.fill" : "mic.slash.fill")
                        .font(.title2)
                    Text(isListening ? "Pause Listening" : "Resume Listening")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isListening ? Color.orange : Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 12)
    }
}

#Preview {
    ContentView()
}

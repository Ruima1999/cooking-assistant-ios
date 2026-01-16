import SwiftUI
import os

@main
struct CookingAssistantApp: App {
    private let logger = Logger(subsystem: "com.example.CookingAssistant", category: "lifecycle")

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    logger.info("App launched")
                }
        }
    }
}

import SwiftUI

struct AuthView: View {
    @ObservedObject var authStore: AuthStore

    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = true

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Welcome")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Sign in to start cooking hands-free.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 16) {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage = authStore.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task {
                    if isSigningIn {
                        await authStore.signIn(email: email, password: password)
                    } else {
                        await authStore.signUp(email: email, password: password)
                    }
                }
            } label: {
                HStack {
                    if authStore.isLoading {
                        ProgressView()
                    }
                    Text(isSigningIn ? "Sign In" : "Create Account")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(authStore.isLoading || email.isEmpty || password.isEmpty)

            Button {
                withAnimation(.easeInOut) {
                    isSigningIn.toggle()
                }
            } label: {
                Text(isSigningIn ? "Need an account? Sign up" : "Already have an account? Sign in")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(24)
    }
}

#Preview {
    AuthView(authStore: AuthStore())
}

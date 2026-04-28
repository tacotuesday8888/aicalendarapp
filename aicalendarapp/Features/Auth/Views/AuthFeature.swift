import SwiftUI
import Combine

@MainActor
final class AuthViewModel: ObservableObject {
    enum Mode: String, CaseIterable {
        case signIn = "Sign In"
        case signUp = "Create Account"
    }

    @Published var mode: Mode = .signIn
    @Published var email = ""
    @Published var password = ""
    @Published var displayName = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let authService: AuthServicing
    private let userService: UserServicing
    private let analyticsService: AnalyticsServicing

    init(authService: AuthServicing, userService: UserServicing, analyticsService: AnalyticsServicing) {
        self.authService = authService
        self.userService = userService
        self.analyticsService = analyticsService
    }

    func submit() async {
        errorMessage = nil

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEmail(trimmedEmail) else {
            errorMessage = "Enter a valid email address."
            return
        }
        if mode == .signUp {
            guard password.count >= 8 else {
                errorMessage = "Use at least 8 characters for your password."
                return
            }
            guard !trimmedDisplayName.isEmpty else {
                errorMessage = "Enter your display name."
                return
            }
        }

        isLoading = true
        defer { isLoading = false }

        do {
            switch mode {
            case .signIn:
                _ = try await authService.signIn(email: trimmedEmail, password: password)
                analyticsService.track(event: "auth_signed_in")
            case .signUp:
                _ = try await authService.signUp(email: trimmedEmail, password: password, displayName: trimmedDisplayName)
                analyticsService.track(event: "auth_signed_up")
            }
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Authentication failed.").errorDescription
            analyticsService.record(error: error, context: "auth_submit")
        }
    }

    func signInWithApple() async {
        await signInWithProvider(name: "apple") {
            _ = try await authService.signInWithApple()
        }
    }

    func signInWithGoogle() async {
        await signInWithProvider(name: "google") {
            _ = try await authService.signInWithGoogle()
        }
    }

    private func signInWithProvider(name: String, action: () async throws -> Void) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await action()
            analyticsService.track(event: "auth_provider_success", parameters: ["provider": name])
        } catch {
            errorMessage = AppError.wrap(error, fallback: "Unable to sign in with \(name.capitalized).").errorDescription
            analyticsService.record(error: error, context: "auth_provider_\(name)")
        }
    }

    private static func isValidEmail(_ value: String) -> Bool {
        let pattern = #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct AuthView: View {
    @StateObject private var viewModel: AuthViewModel

    init(viewModel: AuthViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SWLiquidGlassBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Student planner, not another empty shell.")
                            .font(.largeTitle.bold())
                        Text("Sign in to manage goals, sessions, check-ins, AI plans, and your synced calendar in one place.")
                            .foregroundStyle(AppTheme.textSecondary)

                        SWGlassPanel {
                            VStack(alignment: .leading, spacing: 16) {
                                Picker("Mode", selection: $viewModel.mode) {
                                    ForEach(AuthViewModel.Mode.allCases, id: \.self) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                if viewModel.mode == .signUp {
                                    TextField("Display name", text: $viewModel.displayName)
                                        .textFieldStyle(.roundedBorder)
                                }

                                TextField("Email", text: $viewModel.email)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.emailAddress)
                                    .textFieldStyle(.roundedBorder)

                                SecureField("Password", text: $viewModel.password)
                                    .textFieldStyle(.roundedBorder)

                                Button {
                                    Task { await viewModel.submit() }
                                } label: {
                                    if viewModel.isLoading {
                                        ProgressView()
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        Text(viewModel.mode.rawValue)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .buttonStyle(SWGlassCTAButtonStyle())
                                .disabled(
                                    viewModel.isLoading ||
                                    viewModel.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                    viewModel.password.isEmpty ||
                                    (viewModel.mode == .signUp && viewModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                )

                                Divider()

                                Button("Continue with Apple") {
                                    Task { await viewModel.signInWithApple() }
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                                .disabled(viewModel.isLoading)

                                Button("Continue with Google") {
                                    Task { await viewModel.signInWithGoogle() }
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                                .disabled(viewModel.isLoading)

                                if let errorMessage = viewModel.errorMessage {
                                    Text(errorMessage)
                                        .foregroundStyle(.red)
                                        .font(.footnote)
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
            .navigationBarHidden(true)
        }
    }
}

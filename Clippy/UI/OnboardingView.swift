import SwiftUI

struct OnboardingView: View {
    @Binding var selectedAIService: AIServiceType
    @State private var currentStep = 0
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentStep) {
                welcomeStep.tag(0)
                permissionsStep.tag(1)
                aiStep.tag(2)
                tryItStep.tag(3)
            }
            .tabViewStyle(.automatic)

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

                if currentStep < 3 {
                    Button("Skip") {
                        onComplete()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.system(size: 12))
                }

                Spacer()

                // Step indicators
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { step in
                        Circle()
                            .fill(step == currentStep ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                if currentStep < 3 {
                    Button("Next") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Using Clippy") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "paperclip.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))

            Text("Welcome to Clippy")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("Your AI-powered clipboard companion.\nSearch, organize, and paste anything from your clipboard history.")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 380)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Permissions")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Clippy needs a couple of permissions to work its magic.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                permissionRow(
                    icon: "hand.raised.fill",
                    color: .blue,
                    title: "Accessibility",
                    description: "Enables keyboard shortcuts and paste-to-app",
                    isGranted: AXIsProcessTrusted(),
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )

                permissionRow(
                    icon: "camera.metering.matrix",
                    color: .purple,
                    title: "Screen Recording",
                    description: "Enables vision parsing (Option+V) to capture screen text",
                    isGranted: CGPreflightScreenCaptureAccess(),
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding(32)
    }

    private func permissionRow(icon: String, color: Color, title: String, description: String, isGranted: Bool, settingsURL: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Grant") {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Step 3: Choose AI

    private var aiStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Choose Your AI")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .padding(.top, 16)

                Text("Clippy uses AI for smart tagging and search. You can change this later in Settings.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                VStack(spacing: 10) {
                    aiOptionCard(
                        service: .local,
                        icon: "desktopcomputer",
                        title: "Local AI (Recommended)",
                        description: "Runs on your Mac. Private, no API key needed.",
                        badge: "Private"
                    )

                    aiOptionCard(
                        service: .gemini,
                        icon: "cloud",
                        title: "Gemini (Cloud)",
                        description: "Google's Gemini API. Requires an API key.",
                        badge: nil
                    )

                    aiOptionCard(
                        service: .claude,
                        icon: "brain.head.profile",
                        title: "Claude (Cloud)",
                        description: "Anthropic's Claude API. Requires an API key.",
                        badge: nil
                    )

                    aiOptionCard(
                        service: .openai,
                        icon: "sparkle",
                        title: "OpenAI (Cloud)",
                        description: "GPT-4o Mini. Requires an API key.",
                        badge: nil
                    )

                    aiOptionCard(
                        service: .ollama,
                        icon: "server.rack",
                        title: "Ollama (Local)",
                        description: "Self-hosted models via Ollama. No API key needed.",
                        badge: nil
                    )
                }
                .padding(.horizontal, 24)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
        }
    }

    private func aiOptionCard(service: AIServiceType, icon: String, title: String, description: String, badge: String?) -> some View {
        Button(action: { selectedAIService = service }) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        if let badge = badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: selectedAIService == service ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedAIService == service ? .accentColor : .secondary.opacity(0.4))
                    .font(.system(size: 20))
            }
            .padding(14)
            .background(selectedAIService == service ? Color.accentColor.opacity(0.08) : Color.clear)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selectedAIService == service ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 4: Try It

    private var tryItStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "keyboard.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("You're All Set!")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Here are the shortcuts you'll use every day:")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                shortcutRow(keys: "Cmd+Shift+V", description: "Search your clipboard from anywhere", icon: "magnifyingglass")
                shortcutRow(keys: "Option+X", description: "Ask AI about selected text", icon: "text.bubble")
                shortcutRow(keys: "Option+V", description: "Capture text from screen (OCR)", icon: "camera.viewfinder")
                shortcutRow(keys: "Option+Space", description: "Voice input to AI", icon: "mic.fill")
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding(32)
    }

    private func shortcutRow(keys: String, description: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(keys)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 130, alignment: .leading)

            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

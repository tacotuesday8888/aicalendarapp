import SwiftUI

struct SWLiquidGlassBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.backgroundTop, AppTheme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(AppTheme.primary.opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: -140, y: -220)

            Circle()
                .fill(AppTheme.accent.opacity(0.20))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: 150, y: 210)

            RoundedRectangle(cornerRadius: 96, style: .continuous)
                .fill(AppTheme.surface.opacity(0.65))
                .frame(width: 250, height: 170)
                .blur(radius: 44)
                .rotationEffect(.degrees(18))
                .offset(x: 130, y: -70)

            RoundedRectangle(cornerRadius: 120, style: .continuous)
                .fill(AppTheme.primary.opacity(0.12))
                .frame(width: 280, height: 200)
                .blur(radius: 64)
                .rotationEffect(.degrees(-22))
                .offset(x: -140, y: 260)
        }
        .ignoresSafeArea()
    }
}

struct SWGlassPanel<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    init(
        cornerRadius: CGFloat = AppTheme.cardCornerRadius,
        padding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.glassHighlight, AppTheme.surface],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .blendMode(.softLight)
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [AppTheme.glassHighlight, AppTheme.border],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: AppTheme.glassShadow, radius: 20, y: 12)
    }
}

struct SWGlassCTAButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.controlCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.primary.opacity(configuration.isPressed ? 0.78 : 0.96),
                                AppTheme.accent.opacity(configuration.isPressed ? 0.74 : 0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.controlCornerRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            .shadow(color: AppTheme.primary.opacity(0.16), radius: configuration.isPressed ? 8 : 16, y: configuration.isPressed ? 4 : 10)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

private struct SWGlassListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SWLiquidGlassBackground())
    }
}

private struct SWGlassScreenModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SWLiquidGlassBackground())
    }
}

extension View {
    func swGlassListChrome() -> some View {
        modifier(SWGlassListModifier())
    }

    func swGlassScreenBackground() -> some View {
        modifier(SWGlassScreenModifier())
    }
}

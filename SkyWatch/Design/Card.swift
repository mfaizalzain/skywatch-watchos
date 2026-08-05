import SwiftUI

/// The radar's design language, as a reusable container: a cyan-tinted glass
/// panel with a hairline cyan rim, sitting on the true-black scope base.
///
/// The fill is a *visible* cyan tint rather than black-on-black — a pure black
/// fill over the black container background is invisible, so cards would read
/// as nothing at all. The tint + rim read as instrument chrome and echo the
/// scope's glow. Always-On dims both layers.
///
/// Two shapes: `GlassCard { … }` wraps content; `.glassCardBackground()` on a
/// view. Both draw the same panel.
struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    init(cornerRadius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background(panel)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Palette.dataCyan.opacity(isLuminanceReduced ? 0.02 : 0.08),
                        Palette.dataCyan.opacity(isLuminanceReduced ? 0.01 : 0.035)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        Palette.dataCyan.opacity(isLuminanceReduced ? 0.12 : 0.35),
                        lineWidth: 0.75
                    )
            }
    }
}

extension View {
    /// Paints the glass-card panel behind this view (no padding added — the
    /// caller controls spacing, like a background modifier should).
    func glassCardBackground(cornerRadius: CGFloat = 14) -> some View {
        background(GlassCard(cornerRadius: cornerRadius) { EmptyView() })
    }
}

#Preview("GlassCard") {
    ZStack {
        Palette.scopeBase
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("IDENTITY").font(Typography.sectionHeader).foregroundStyle(Palette.dataCyan)
                Text("MAS123").font(Typography.primaryValue).foregroundStyle(Palette.primaryWhite)
                Text("Boeing 737-800").font(Typography.smallLabel).foregroundStyle(Palette.primaryWhite.opacity(0.6))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
    }
}

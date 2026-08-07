import SwiftUI

/// A persistent red banner announcing an aircraft that is declaring an
/// emergency (squawk 7500 / 7600 / 7700, or an active `emergency` field).
///
/// The one thing the wearer must not miss is promoted from a small red glyph
/// among the blips to a banner on the scope and the list. Tapping it opens the
/// aircraft's detail screen.
struct EmergencyBanner: View {
    let target: TrackedTarget
    var isLuminanceReduced = false

    private var squawkText: String {
        guard let squawk = target.aircraft.squawk, target.aircraft.hasEmergencySquawk else {
            return "EMG"
        }
        return squawk
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
            Text("\(squawkText) · \(target.aircraft.displayName)")
                .font(Typography.smallLabel.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 2)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.7)
        }
        .foregroundStyle(Palette.dimmed(Palette.warningRed, isLuminanceReduced: isLuminanceReduced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Palette.warningRed.opacity(isLuminanceReduced ? 0.10 : 0.16))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Palette.warningRed.opacity(isLuminanceReduced ? 0.4 : 0.7), lineWidth: 0.75)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aircraft declaring an emergency")
        .accessibilityValue("\(target.aircraft.displayName), squawk \(squawkText)")
    }
}

#Preview("Emergency banner") {
    ZStack {
        Palette.scopeBase
        VStack(spacing: 8) {
            EmergencyBanner(target: PreviewData.emergencyTarget)
            EmergencyBanner(target: PreviewData.emergencyTarget, isLuminanceReduced: true)
        }
        .padding()
    }
}

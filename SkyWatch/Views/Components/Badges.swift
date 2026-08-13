import SwiftUI

/// A one- or two-letter tag. Small, quiet, and coloured only by what it means.
struct Badge: View {
    let text: String
    let color: Color
    var isLuminanceReduced = false

    var body: some View {
        Text(text)
            .font(Typography.smallValue)
            .fontWeight(.semibold)
            .foregroundStyle(Palette.dimmed(color, isLuminanceReduced: isLuminanceReduced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Palette.dimmed(color, isLuminanceReduced: isLuminanceReduced).opacity(0.6), lineWidth: 0.5)
            )
    }
}

/// The badges a target has earned, in severity order. Nothing decorative gets in here.
struct TargetBadges: View {
    let target: TrackedTarget
    var isLuminanceReduced = false

    var body: some View {
        HStack(spacing: 3) {
            if target.aircraft.hasEmergencySquawk, let squawk = target.aircraft.squawk {
                Badge(text: squawk, color: Palette.warningRed, isLuminanceReduced: isLuminanceReduced)
            } else if target.aircraft.emergency.isActive {
                Badge(text: "EMG", color: Palette.warningRed, isLuminanceReduced: isLuminanceReduced)
            }

            if target.aircraft.isMilitary {
                Badge(text: "MIL", color: Palette.dataCyan, isLuminanceReduced: isLuminanceReduced)
            }

            switch target.position.source {
            case .mlat:
                Badge(text: "MLAT", color: Palette.cautionAmber, isLuminanceReduced: isLuminanceReduced)
            case .estimated:
                Badge(text: "EST", color: Palette.cautionAmber, isLuminanceReduced: isLuminanceReduced)
            case .reported:
                EmptyView()
            }

            if target.position.isStale, let age = target.position.ageSeconds {
                Badge(text: Units.age(seconds: age), color: Palette.cautionAmber, isLuminanceReduced: isLuminanceReduced)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A bearing arrow, rotated to point where the target actually is relative to the wearer.
struct BearingArrow: View {
    let degrees: Double
    var color: Color = Palette.dataCyan

    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(degrees))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// Climb, level, descent. Level draws nothing — an absent chevron is quieter than a dash and says
/// the same thing.
struct VerticalTrendChevron: View {
    let trend: VerticalTrend
    var color: Color = Palette.dataCyan

    var body: some View {
        switch trend {
        case .climbing:
            Image(systemName: "chevron.up")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        case .descending:
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        case .level:
            EmptyView()
        }
    }
}

#Preview("Badges") {
    VStack(alignment: .leading, spacing: 6) {
        TargetBadges(target: PreviewData.emergencyTarget)
        TargetBadges(target: PreviewData.militaryTarget)
        TargetBadges(target: PreviewData.staleMLATTarget)
        HStack {
            BearingArrow(degrees: 210)
            VerticalTrendChevron(trend: .descending)
            VerticalTrendChevron(trend: .climbing)
        }
    }
    .padding()
    .background(Palette.scopeBase)
}

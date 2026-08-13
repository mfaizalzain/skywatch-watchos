import SwiftUI

/// The one line pinned to the bottom of the scope: what is closest, how far, which way, how high.
struct NearestCallout: View {
    let target: TrackedTarget
    let unitSystem: UnitSystem
    /// Heading to subtract so the arrow points where you'd actually turn. Nil in north-up mode.
    let deviceHeading: Double?

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var arrowDegrees: Double {
        guard let deviceHeading else { return target.bearingDegrees }
        return Geodesy.relativeBearing(absolute: target.bearingDegrees, deviceHeading: deviceHeading)
    }

    private var distance: FormattedValue {
        Units.distance(nauticalMiles: target.distanceNM, system: unitSystem)
    }

    private var altitude: FormattedValue? {
        target.aircraft.altBaro.map { Units.altitude($0, system: unitSystem) }
    }

    /// The "look up now" moment: when the nearest aircraft will pass closest inside a minute,
    /// that countdown matters more than its altitude. Clock + seconds mirror the list.
    private var approachCountdown: Int? {
        guard let approach = target.closestApproach,
              approach.timeToClosestApproach > 0,
              approach.timeToClosestApproach <= 60 else { return nil }
        return Int(approach.timeToClosestApproach.rounded())
    }

    private var accessibilityValue: String {
        if let countdown = approachCountdown {
            return "\(target.accessibilityDescription(unitSystem: unitSystem)), passes closest in \(countdown) seconds"
        }
        return target.accessibilityDescription(unitSystem: unitSystem)
    }

    var body: some View {
        HStack(spacing: 5) {
            BearingArrow(
                degrees: arrowDegrees,
                color: Palette.dimmed(Palette.targetMagenta, isLuminanceReduced: isLuminanceReduced)
            )

            Text(target.aircraft.displayName)
                .callsignStyle(Typography.value)
                .foregroundStyle(Palette.dimmed(Palette.targetMagenta, isLuminanceReduced: isLuminanceReduced))

            Spacer(minLength: 2)

            Text(distance.value)
                .font(Typography.smallValue)
                .foregroundStyle(Palette.dimmed(Palette.primaryWhite, isLuminanceReduced: isLuminanceReduced))

            if let countdown = approachCountdown {
                Image(systemName: "clock")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced))
                Text("\(countdown)s")
                    .font(Typography.smallValue)
                    .foregroundStyle(Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced))
            } else if let altitude {
                VerticalTrendChevron(
                    trend: target.aircraft.verticalTrend,
                    color: Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced)
                )
                Text(altitude.value)
                    .font(Typography.smallValue)
                    .foregroundStyle(Palette.dimmed(Palette.primaryWhite, isLuminanceReduced: isLuminanceReduced))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Palette.dataCyan.opacity(isLuminanceReduced ? 0.04 : 0.14),
                            Palette.dataCyan.opacity(isLuminanceReduced ? 0.02 : 0.07)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    Palette.dataCyan.opacity(isLuminanceReduced ? 0.15 : 0.4),
                    lineWidth: 0.75
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nearest target")
        .accessibilityValue(accessibilityValue)
    }
}

#Preview("Callout") {
    ZStack {
        Palette.scopeBase
        NearestCallout(
            target: PreviewData.airlinerTarget,
            unitSystem: .aviation,
            deviceHeading: 45
        )
    }
}

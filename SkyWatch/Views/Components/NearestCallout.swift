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

            if let altitude {
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
                .fill(Color.black.opacity(isLuminanceReduced ? 0.0 : 0.55))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nearest target")
        .accessibilityValue(target.accessibilityDescription(unitSystem: unitSystem))
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

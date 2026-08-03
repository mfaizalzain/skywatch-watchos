import SwiftUI

/// Everything the app can say when it has nothing to show, in one place.
///
/// Each case states what happened and what to do about it. None of them apologise, and none of them
/// are vague — "airplanes.live isn't responding" is actionable; "something went wrong" is not.
enum FailureState: Equatable {
    case noAircraft(radius: ScanRadius)
    case locationDenied
    case offline(dataAge: TimeInterval?)
    case rateLimited
    case server
    case decoding
    case awaitingLocation
    case locationUnavailable

    init?(error: SkyWatchError?, dataAge: TimeInterval?) {
        switch error {
        case .none: return nil
        case .offline: self = .offline(dataAge: dataAge)
        case .rateLimited: self = .rateLimited
        case .server, .apiMessage: self = .server
        case .decoding: self = .decoding
        case .locationDenied: self = .locationDenied
        case .locationUnavailable: self = .locationUnavailable
        }
    }

    var symbol: String {
        switch self {
        case .noAircraft: "airplane.circle"
        case .locationDenied, .locationUnavailable, .awaitingLocation: "location.slash"
        case .offline: "wifi.slash"
        case .rateLimited: "tortoise"
        case .server, .decoding: "antenna.radiowaves.left.and.right.slash"
        }
    }

    var message: String {
        switch self {
        case .noAircraft(let radius):
            "No aircraft within \(Int(radius.nauticalMiles)) nm."
        case .locationDenied:
            "SkyWatch needs your location to find nearby aircraft."
        case .locationUnavailable:
            "Waiting for a location fix. Step outside or move near a window."
        case .awaitingLocation:
            "Finding your location."
        case .offline(let age):
            if let age {
                "No connection. Showing aircraft from \(Units.age(seconds: age)) ago."
            } else {
                "No connection."
            }
        case .rateLimited:
            "Slowing down to stay within the API limit."
        case .server:
            "airplanes.live isn't responding."
        case .decoding:
            "airplanes.live sent something SkyWatch couldn't read."
        }
    }

    /// The colour is the severity. Amber for "this will resolve itself", red for "you must act".
    var tint: Color {
        switch self {
        case .noAircraft, .awaitingLocation: Palette.dataCyan
        case .rateLimited, .offline, .locationUnavailable: Palette.cautionAmber
        case .locationDenied, .server, .decoding: Palette.warningRed
        }
    }

    enum Action: Equatable {
        case widen(ScanRadius)
        case openSettings
        case retry
        /// Nothing to offer. A rate limit recovers on its own; a button would be a lie.
        case noAction
    }

    /// A rate limit recovers on its own, so it gets no button — offering one would be a lie.
    var action: Action {
        switch self {
        case .noAircraft(let radius):
            radius.wider.map { Action.widen($0) } ?? .noAction
        case .locationDenied:
            .openSettings
        case .offline, .server, .decoding, .locationUnavailable:
            .retry
        case .rateLimited, .awaitingLocation:
            .noAction
        }
    }
}

struct FailureStateView: View {
    let state: FailureState
    var onWiden: ((ScanRadius) -> Void)?
    var onRetry: (() -> Void)?

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: state.symbol)
                .font(.title3)
                .foregroundStyle(Palette.dimmed(state.tint, isLuminanceReduced: isLuminanceReduced))

            Text(state.message)
                .font(Typography.label)
                .foregroundStyle(Palette.dimmed(Palette.primaryWhite, isLuminanceReduced: isLuminanceReduced))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Always-On is a glance, not an interaction — no buttons to fat-finger while dimmed.
            if !isLuminanceReduced {
                actionButton
            }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state.action {
        case .widen(let radius):
            Button("Widen to \(Int(radius.nauticalMiles)) nm") { onWiden?(radius) }
                .font(Typography.label)
                .buttonStyle(.bordered)
                .tint(Palette.dataCyan)
        case .openSettings:
            // watchOS has no URL into its own Settings app, so say where to go instead of opening
            // a link that would silently fail.
            Text("Settings › Privacy & Security › Location Services › SkyWatch")
                .font(Typography.smallLabel)
                .foregroundStyle(Palette.dataCyan)
                .multilineTextAlignment(.center)
        case .retry:
            Button("Retry") { onRetry?() }
                .font(Typography.label)
                .buttonStyle(.bordered)
                .tint(Palette.dataCyan)
        case .noAction:
            EmptyView()
        }
    }
}

#Preview("No aircraft") {
    FailureStateView(state: .noAircraft(radius: .twenty))
        .background(Palette.scopeBase)
}

#Preview("Location denied") {
    FailureStateView(state: .locationDenied)
        .background(Palette.scopeBase)
}

#Preview("Offline") {
    FailureStateView(state: .offline(dataAge: 124))
        .background(Palette.scopeBase)
}

#Preview("Rate limited") {
    FailureStateView(state: .rateLimited)
        .background(Palette.scopeBase)
}

#Preview("Server error") {
    FailureStateView(state: .server)
        .background(Palette.scopeBase)
}

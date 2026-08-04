import SwiftUI

/// Destinations that aren't an aircraft. Aircraft push by hex, which is a `String`.
enum Route: Hashable {
    case settings
}

enum ScanTab: Hashable {
    case radar
    case list
    case track
}

private struct RequestTrackTabKey: EnvironmentKey {
    static let defaultValue: @Sendable () -> Void = {}
}

extension EnvironmentValues {
    /// Switches the root tab to Track, popping any pushed screen first. Set by
    /// `RootView`; used by the list's swipe action and the detail screen's
    /// track button to hand a callsign to the Track tab.
    var requestTrackTab: @Sendable () -> Void {
        get { self[RequestTrackTabKey.self] }
        set { self[RequestTrackTabKey.self] = newValue }
    }
}

struct RootView: View {
    @Environment(ScanStore.self) private var store
    @Environment(FlightTrackStore.self) private var flightStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    @State private var tab: ScanTab = .radar
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            TabView(selection: $tab) {
                RadarView()
                    .tag(ScanTab.radar)

                AircraftListView()
                    .tag(ScanTab.list)

                TrackFlightView()
                    .tag(ScanTab.track)
            }
            .tabViewStyle(.verticalPage)
            .containerBackground(Palette.scopeBase, for: .navigation)
            .navigationDestination(for: String.self) { hex in
                AircraftDetailView(hex: hex)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .settings: SettingsView()
                }
            }
        }
        // Set on the NavigationStack, not inside it: pushed destinations
        // (aircraft detail) inherit the stack's environment, so the detail
        // screen's "Track this flight" button can actually switch tabs.
        .environment(\.requestTrackTab) {
            // Pop any pushed screen (e.g. an aircraft detail) so the Track
            // tab is actually visible, then switch to it.
            path = NavigationPath()
            tab = .track
        }
        // Polling is tied to the scene, not to a view's lifetime: nothing runs in the background.
        .onChange(of: scenePhase, initial: true) { _, phase in
            store.setActive(phase == .active)
            flightStore.setActive(phase == .active)
        }
        .onChange(of: isLuminanceReduced, initial: true) { _, reduced in
            store.isLuminanceReduced = reduced
            flightStore.isLuminanceReduced = reduced
        }
    }
}

#Preview("Root") {
    RootView()
        .environment(ScanStore.previewStore(targets: PreviewData.handful))
        .environment(FlightTrackStore())
}

#Preview("Always-On") {
    RootView()
        .environment(ScanStore.previewStore(targets: PreviewData.handful, isLuminanceReduced: true))
        .environment(FlightTrackStore())
        .environment(\.isLuminanceReduced, true)
}

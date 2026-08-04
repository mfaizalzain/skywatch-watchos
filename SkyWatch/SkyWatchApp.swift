import SwiftUI

/// Explicitly main-actor isolated: `ScanStore` is `@MainActor`, and under Swift 6 the `@State`
/// initialiser below would otherwise be a call into main-actor code from a nonisolated context.
@main
@MainActor
struct SkyWatchApp: App {
    /// One store for the whole app. Created here rather than in a view so its polling task outlives
    /// any individual screen — and stops the moment the scene does.
    @State private var store = ScanStore()
    @State private var flightStore = FlightTrackStore()

    init() {
        // Without this, flight alerts are suppressed while the app is on
        // screen — the exact moment someone is waiting at the airport.
        UNUserNotificationCenter.current().delegate = FlightAlertPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(flightStore)
                .tint(Palette.dataCyan)
                .preferredColorScheme(.dark)
        }
    }
}

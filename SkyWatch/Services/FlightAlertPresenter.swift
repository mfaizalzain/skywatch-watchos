import Foundation
import UserNotifications

/// Presents flight alerts even while SkyWatch is on screen.
///
/// On watchOS, like iOS, a notification is *not* presented when the app that
/// scheduled it is in the foreground — and the airport-pickup moment is
/// precisely when the Track screen is open on the wrist. Without a delegate
/// the 30/15/landed alerts would silently vanish into the notification centre
/// and never vibrate. This delegate re-enables banner + sound (vibration)
/// delivery for exactly that case.
final class FlightAlertPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FlightAlertPresenter()

    private override init() {
        super.init()
    }

    /// Always show flight alerts as banners with sound, foreground or not.
    /// Sound on watchOS *is* the haptic engine — `.default` sound is what
    /// makes the watch buzz.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

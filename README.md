# SkyWatch

A standalone Apple Watch scanner for aircraft flying near you, built on the free
[airplanes.live](https://airplanes.live) ADS-B API.

No iPhone app, no `WatchConnectivity`, no third-party dependencies, no API key, no analytics. The
watch talks to exactly one host — `api.airplanes.live` — and nothing else.

Built for personal sideloading. It is not intended for the App Store.

---

## What it does

- **Radar** — a circular scope with you at the centre. Blips are triangles rotated to each
  aircraft's track, with a short fading tail so you can see motion rather than just position. Range
  rings sit at ⅓, ⅔ and full range; the sweep line points where the watch is facing. The Digital
  Crown snaps the radius through 5 / 10 / 20 / 50 nm with a haptic detent at each stop.
- **List** — everything in range, nearest first, two lines per aircraft: callsign and badges, then
  distance, bearing arrow, altitude with a climb/descent chevron, and ground speed. Swipe to pin.
- **Detail** — identity, position, motion, status and signal quality, plus a small map showing the
  aircraft, you, and the line between. Only fields the feed actually sent are shown.
- **Settings** — radius, refresh interval, units, heading-up vs north-up, filters, proximity haptic.
- **Complication** — a Smart Stack widget with the count in range and the nearest aircraft.

## Requirements

- Xcode 26.x with the watchOS 26 SDK
- Apple Watch running watchOS 26.0 or later
- An Apple Developer Program account for the App Group (a free personal team cannot use one; see
  *Building without an App Group* below)

## First-time setup

The project ships with the bundle identifiers already set to `com.fmz.skywatch`. If you are not
signing as that team, change them in three places:

| Where | Value |
|---|---|
| `SkyWatch` target → Signing & Capabilities | `com.fmz.skywatch` |
| `SkyWatchWidget` target → Signing & Capabilities | `com.fmz.skywatch.widget` |
| Both `.entitlements` files | `group.com.fmz.skywatch` |

Then:

1. Open `SkyWatch.xcodeproj`.
2. Select each of the three targets, set your team under **Signing & Capabilities**, and leave
   **Automatically manage signing** checked.
3. Confirm the **App Groups** capability is present on both `SkyWatch` and `SkyWatchWidget` and that
   the same group is ticked for both. The app writes its last scan there; the widget reads it.

## Path A — direct install from Xcode

Day-to-day development.

1. Pair the watch to Xcode: **Window → Devices and Simulators**, with the watch unlocked, on its
   charger, on the same Wi-Fi as the Mac, and its paired iPhone nearby.
2. Select the watch as the run destination and build. **The first wireless install takes 5–15
   minutes** — this is normal, and later builds are much faster.
3. On the watch: **Settings → General → VPN & Device Management** → trust the developer certificate.
   With a paid account the profile lasts a year, so this is a one-time step.

## Path B — TestFlight

Recommended once it is stable. Survives a watch reset or a Mac rebuild without touching Xcode.

1. **Product → Archive**, then distribute to App Store Connect.
2. Add yourself as an internal tester. Internal testing needs no App Review.
3. Install from the TestFlight app on the paired iPhone; it pushes to the watch over the air.
4. Builds expire after **90 days**, so re-upload quarterly.

## Building without an App Group

The App Group is only used to hand the last scan to the complication. If you are on a free personal
team, or just want the app without the widget:

1. Delete the `SkyWatchWidget` target and the **Embed Foundation Extensions** build phase.
2. Remove `CODE_SIGN_ENTITLEMENTS` from the `SkyWatch` target's build settings.

`SharedStore` falls back to `UserDefaults.standard` when the group container is unavailable, so
nothing else needs to change and settings keep persisting.

## Tests

`⌘U` runs the suite. `SkyWatchTests` is a logic-test bundle with no host application — the
UI-independent sources are compiled into it directly — so it runs in the simulator without
installing the app.

Covered: response decoding (including `alt_baro: "ground"`, `~`-prefixed hexes, `lastPosition`-only
and `rr_lat`-only targets, `msg` errors, and a malformed member inside a valid `ac` array),
great-circle distance and bearing against published examples, antimeridian and pole cases, the
heading filter's 359° → 0° wrap, rate-limiter spacing under concurrent callers, and the full merge
lifecycle from first appearance to being dropped after two missed cycles.

The rate-limiter tests wait on a real clock, so the suite takes roughly ten seconds.

## Design notes

**The colour language is EFIS, not "radar green."** Every colour means one thing:

| Token | Meaning |
|---|---|
| black | scope background — OLED pixels off, real battery saving on Always-On |
| cyan | reference data: range rings, labels, secondary readouts |
| magenta | the nearest or pinned target — the PFD's "active" colour |
| amber | stale positions, MLAT and estimated targets, reduced GPS accuracy |
| red | emergency squawks and any active `emergency` field |
| white | primary numeric values |

Nothing is coloured decoratively. If something is amber, its position is uncertain.

**Data quality is never hidden.** A position from `lastPosition` is badged with its age; an
`rr_lat`/`rr_lon` position is drawn as a hollow ring and labelled `EST`, because it is the
receiver's rough guess and not a fix at all; MLAT is badged; `mode_s` targets have no position and
are counted under "heard, no position" rather than being drawn somewhere plausible.

**Rate limiting is structural.** Every endpoint, including the detail screen's, goes through one
actor that reserves its slot before suspending, so concurrent callers queue instead of firing
together. The minimum spacing is 1.2 s against a documented limit of 1 request per second.

**Battery.** Polling only runs while the scene is active, backs off to 60 s when the display is
luminance-reduced, and the compass runs only while the radar is on screen. Location accuracy is set
to 100 m with a 250 m distance filter — far more than a 20 nm radius needs.

## Deliberately not included

- **Background location.** The app scans while you are looking at it, and not otherwise.
- **Push notifications.** They would need a server polling the API for you. The on-device proximity
  haptic covers the same need while the app is open.
- **CloudKit.** Settings are a handful of values in an App Group.

## Complication expectations

watchOS grants a widget a limited background budget: expect an effective refresh somewhere between
15 and 60 minutes, whatever the timeline asks for. This is enforced by the OS and is **not**
affected by developer account tier. The complication shows the app's last foreground scan, with its
age when it is over half an hour old, and acts as a launch shortcut. It is not a live feed, and the
code does not try to work around the budget.

## Attribution

Data from [airplanes.live](https://airplanes.live) — unfiltered community ADS-B and MLAT. No SLA,
no uptime guarantee, **non-commercial use only**.

Coverage is community-fed and uneven, so an empty sky is a normal and frequent result in many
regions. If you end up using this regularly, consider
[feeding data back](https://airplanes.live/get-started/) — the network runs on volunteer receivers.

## Regenerating the project file

`SkyWatch.xcodeproj/project.pbxproj` was written by `tools_genproj.py` rather than by Xcode. If it
ever gets mangled, `python3 tools_genproj.py` rebuilds it from what is on disk. Adding a file in
Xcode normally is fine — the script is a repair tool, not a required step.

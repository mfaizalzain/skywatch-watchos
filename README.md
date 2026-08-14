# SkyWatch

A standalone Apple Watch scanner for aircraft flying near you, built on
[FlightAware AeroAPI](https://www.flightaware.com/aeroapi).

No iPhone app, no `WatchConnectivity`, no third-party dependencies, no analytics. The watch talks
to exactly one host — `aeroapi.flightaware.com` — and nothing else.

Built for personal sideloading. It is not intended for the App Store. **You need your own AeroAPI
key to build it** — see [AeroAPI key](#aeroapi-key) below. The key is never in this repository.

> **Note on the previous data source.** SkyWatch was originally built on the free
> [airplanes.live](https://airplanes.live) ADS-B API. That API is now gated — it returns HTTP 403
> to unregistered clients — so the app moved to AeroAPI, which needs a key. Some ADS-B-only fields
> went away with it: squawk and emergency status, ICAO hex, registration, and the military/LADD
> flags have no AeroAPI equivalent and the features built on them were removed. Route (origin →
> destination) is now free with every scan, where it used to need a separate lookup.

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
- **Track** — enter a flight number (e.g. `MH123` or `MAS123`), pick the arrival airport, and get a
  live ETA countdown to landing with watch notifications at **30 min**, **15 min**, and **on the
  ground** — built for meeting someone at the gate. A green **● LIVE** badge shows the flight is
  transmitting a position right now; ETA comes from the aircraft's live position and ground speed.
  Alerts vibrate the watch (a strong buzz on landing), and the screen also shows the airline's
  *official* status, terminal, gate and estimated arrival — with the landed alert triggered by the
  airline's own status rather than inferred from the position feed. Tracking stops once it lands
  (the final state stays on screen until you dismiss it), so nothing keeps polling afterwards.
- **Settings** — radius, refresh interval (10 / 20 / 60 s), units, heading-up vs north-up, filters, proximity haptic.
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

Covered: response decoding (altitude in hundreds of feet, ground traffic, `update_type` mapping to
a position source, position age derived from the timestamp including clock skew, `ident_prefix`
labels, and a malformed member inside a valid `flights` array), bounding-box construction, great-circle distance and bearing against published examples, antimeridian and pole cases, the
heading filter's 359° → 0° wrap, rate-limiter spacing under concurrent callers, the full merge
lifecycle from first appearance to being dropped after two missed cycles, and flight tracking —
flight-number parsing (IATA → ICAO callsign conversion, normalisation, garbage rejection), ETA
math, the one-shot 30/15/landed alert state machine, live/not-live phase logic, landed-after-
disappearance detection, airport-catalog sanity (unique IATA codes, valid coordinates), and the
AeroAPI layer — decoding a real FlightAware response (ISO8601 dates, gate/runway times, terminal
and gate), status-summary parsing ("Arrived / Gate Arrival" → arrived), landed detection, and the
occurrence picker (an en-route flight beats tonight's scheduled one, which beats tomorrow's; a
flight that landed this morning is still picked so the pickup alert fires).

The rate-limiter tests wait on a real clock, so the suite takes roughly ten seconds.

## Design notes

**The colour language is EFIS, not "radar green."** Every colour means one thing:

| Token | Meaning |
|---|---|
| black | scope background — OLED pixels off, real battery saving on Always-On |
| cyan | reference data: range rings, labels, secondary readouts |
| magenta | the nearest or pinned target — the PFD's "active" colour |
| amber | stale positions, MLAT and projected targets, reduced GPS accuracy |
| red | failure states that need you to act |
| white | primary numeric values |

Nothing is coloured decoratively. If something is amber, its position is uncertain.

**Data quality is never hidden.** Every position carries AeroAPI's `update_type`, and the scope
says which it is: a projected position (`update_type: P`, extrapolated by FlightAware rather than
reported) is drawn as a hollow ring and labelled `PROJ`; a multilaterated one is badged `MLAT`;
any position over a minute old is badged with its age. A flight with no `last_position` at all is
not drawn somewhere plausible — it is not drawn.

**Rate limiting is structural.** Every request in the app — the scan loop and the flight tracker
alike — goes through one actor that reserves its slot before suspending, so concurrent callers
queue instead of firing together. The spacing is 7 s, comfortably under the Personal tier's 10
result sets per minute. Because AeroAPI is metered, the detail screen spends no query of its own:
it reads the scan's results, which the poll loop is already refreshing.

**Battery.** Polling only runs while the scene is active, backs off to 2 minutes when the display
is luminance-reduced, and the compass runs only while the radar is on screen. Location accuracy is
set to 100 m with a 250 m distance filter — far more than a 20 nm radius needs. The radar refresh
is user-selectable (10 / 20 / 60 s — the sweet spot: fast enough that nothing visibly moves
between sweeps, slow enough to stay cheap). Flight tracking polls the callsign endpoint on the
same scene-gated cadence but slower — tracking is a wait, not a live radar: 2 minutes on wrist-up,
5 minutes on wrist-down; the official status layer polls at 10 minutes. Every query is billed, so
the refresh interval you pick is the bill you pay — see [AeroAPI key](#aeroapi-key). The alerts are local
notifications fired by the watch itself — no server, no background execution.

**Landing detection is layered.** The position feed has no "landed" field, so the app infers it:
the flight reports zero altitude near the arrival airport, or a tracked flight leaves the feed.
The airline's own status (Scheduled / En Route / Landed / Arrived / Cancelled / Diverted)
overrides the inference — a flight
that has officially arrived triggers the landed alert even after its transponder has gone quiet,
and the screen shows terminal, gate and estimated arrival. ETA stays a great-circle-distance-over-
ground-speed estimate, and a flight that is "not in the feed" may simply not have departed yet or
be out of coverage — the UI says so rather than guessing.

**Flight alerts always vibrate.** watchOS, like iOS, suppresses a scheduled notification while the
app that owns it is foreground — which would be exactly when a picker-up is watching the Track
screen. `FlightAlertPresenter` re-enables banner + sound delivery in the foreground (sound *is*
the haptic engine on a watch), and each milestone also plays a direct `WKInterfaceDevice` haptic
at fire time: a strong `.notification` buzz on landing, a polite `.click` for the 30/15-minutes
heads-up. So the watch vibrates even if the user has notification sounds muted or is wrist-down.

## Deliberately not included

- **Background location.** The app scans while you are looking at it, and not otherwise.
- **Push notifications.** They would need a server polling the API for you. The on-device proximity
  haptic covers the same need while the app is open, and flight tracking arms *local*
  notifications (30 / 15 / landed, with vibration) for each milestone while the Track tab is
  active — no server, no background execution. Every poll re-arms them against the freshest ETA,
  and the notification system delivers them even after the watch screen turns off and the app is
  suspended; the landed alert falls back to the live ETA when no official arrival is known. A
  flight that lands while the app was never running will not notify; the alerts are for a pickup
  wait you started tracking, not a background watch service.
- **CloudKit.** Settings are a handful of values in an App Group.

## AeroAPI key

**Required.** Every screen in the app is fed by AeroAPI, so a build without a key shows "No valid
AeroAPI key" and nothing else. The key is intentionally **not** in this repository — anyone
building SkyWatch brings their own.

1. Sign up for AeroAPI at [flightaware.com/aeroapi](https://www.flightaware.com/aeroapi). The
   **Personal** tier is billed per query against a monthly allowance, and the allowance is doubled
   for ADS-B feeders (PiAware/FlightFeeder accounts get it automatically). Check the current
   pricing page before you pick a refresh interval — the scan loop is the bulk of the usage, and
   the radar's 10/20/60 s setting is what decides your query volume.
2. The app reads the key from the `AEROAPI_KEY` build setting into its `AeroAPIKey` Info.plist
   entry. For a personal build, pass it to `xcodebuild`:
   `xcodebuild … AEROAPI_KEY="your-key"`. The release workflow does this from the
   `AEROAPI_KEY` GitHub Actions secret — add the secret and dispatch.
3. Never commit the key. The Info.plist holds only the `$(AEROAPI_KEY)` placeholder, and the
   build setting is empty in the checked-in project file.

The client is one actor with a 7 s minimum spacing shared by every caller, so nothing in the app
can outrun the Personal tier's limit.

## Complication expectations

watchOS grants a widget a limited background budget: expect an effective refresh somewhere between
15 and 60 minutes, whatever the timeline asks for. This is enforced by the OS and is **not**
affected by developer account tier. The complication shows the app's last foreground scan, with its
age when it is over half an hour old, and acts as a launch shortcut. It is not a live feed, and the
code does not try to work around the budget.

## Attribution

Flight data from [FlightAware AeroAPI](https://www.flightaware.com/aeroapi).

Coverage is good but not total, and the scan returns only flights FlightAware is tracking — an
empty sky is a normal result in quiet regions. FlightAware's coverage is partly community-fed too:
running a [PiAware receiver](https://flightaware.com/adsb/piaware/) also doubles your AeroAPI
allowance.

## Regenerating the project file

`SkyWatch.xcodeproj/project.pbxproj` was written by `tools_genproj.py` rather than by Xcode. If it
ever gets mangled, `python3 tools_genproj.py` rebuilds it from what is on disk. Adding a file in
Xcode normally is fine — the script is a repair tool, not a required step.

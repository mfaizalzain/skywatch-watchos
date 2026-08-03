import SwiftUI
import WidgetKit

@main
struct SkyWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrafficCountWidget()
        NearestAircraftWidget()
    }
}

// MARK: - Timeline

struct ScanEntry: TimelineEntry {
    let date: Date
    let snapshot: ScanSnapshot?
}

/// Reads the snapshot the app wrote to the shared container after its last foreground scan.
///
/// The provider deliberately does **not** call the API. watchOS grants a complication a small
/// background budget — expect an effective refresh somewhere between 15 and 60 minutes, regardless
/// of what you request and regardless of developer account tier. A widget that tried to poll a
/// 1 req/s API on that budget would show data just as old, burn the budget, and risk the app's own
/// refresh allowance. This is a glance and a launch shortcut: "is anything overhead right now?"
struct ScanProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScanEntry {
        ScanEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ScanEntry) -> Void) {
        let snapshot = context.isPreview ? ScanSnapshot.placeholder : SharedStore.load()
        completion(ScanEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScanEntry>) -> Void) {
        let entry = ScanEntry(date: .now, snapshot: SharedStore.load())
        // Asking for 15 minutes is asking; the system decides. There is no point requesting less.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widgets

/// How many aircraft were in range at the last scan.
struct TrafficCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.fmz.skywatch.count", provider: ScanProvider()) { entry in
            TrafficCountView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Traffic")
        .description("Aircraft in range at the last scan.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// The nearest aircraft: callsign, distance, altitude.
struct NearestAircraftWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.fmz.skywatch.nearest", provider: ScanProvider()) { entry in
            NearestAircraftView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Nearest aircraft")
        .description("The closest aircraft at the last scan.")
        .supportedFamilies([.accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Views

struct TrafficCountView: View {
    let entry: ScanEntry

    var body: some View {
        VStack(spacing: -1) {
            Image(systemName: "airplane")
                .font(.system(size: 11))
            Text(entry.snapshot.map { "\($0.count)" } ?? "—")
                .font(.system(.title3, design: .monospaced))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .widgetAccentable()
        .accessibilityLabel("Aircraft in range")
        .accessibilityValue(countDescription)
    }

    private var countDescription: String {
        guard let snapshot = entry.snapshot else { return "No recent scan" }
        let staleness = snapshot.age > 1800 ? ", from \(Units.age(seconds: snapshot.age)) ago" : ""
        return "\(snapshot.count) within \(Int(snapshot.radiusNM)) nautical miles\(staleness)"
    }
}

struct NearestAircraftView: View {
    let entry: ScanEntry
    @Environment(\.widgetFamily) private var family

    private var unitSystem: UnitSystem { SharedStore.unitSystem }

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: "airplane")
                .widgetLabel {
                    Text(cornerLabel)
                        .monospacedDigit()
                }
                .widgetAccentable()
                .accessibilityLabel(accessibilityDescription)
        case .accessoryInline:
            Text(inlineLabel)
                .accessibilityLabel(accessibilityDescription)
        default:
            rectangular
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: "airplane")
                    .font(.system(size: 10))
                Text(entry.snapshot?.nearest?.callsign ?? "No traffic")
                    .font(.system(.body, design: .monospaced))
                    .fontWidth(.compressed)
                    .lineLimit(1)
            }
            .widgetAccentable()

            if let nearest = entry.snapshot?.nearest {
                Text(detailLine(nearest))
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
            } else if let snapshot = entry.snapshot {
                Text("within \(Int(snapshot.radiusNM)) nm")
                    .font(.system(.caption2, design: .rounded))
            }

            if let snapshot = entry.snapshot, snapshot.age > 1800 {
                // The complication cannot refresh on demand, so it says how old it is rather than
                // implying it is live.
                Text(Units.age(seconds: snapshot.age) + " ago")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailLine(_ nearest: ScanSnapshot.NearestSummary) -> String {
        let distance = Units.distance(nauticalMiles: nearest.distanceNM, system: unitSystem)
        if nearest.isOnGround { return "\(distance.combined) · GND" }
        guard let feet = nearest.altitudeFeet else { return distance.combined }
        return "\(distance.combined) · \(Units.altitude(feet: Double(feet), system: unitSystem).combined)"
    }

    private var cornerLabel: String {
        guard let nearest = entry.snapshot?.nearest else { return "—" }
        return Units.distance(nauticalMiles: nearest.distanceNM, system: unitSystem).combined
    }

    private var inlineLabel: String {
        guard let nearest = entry.snapshot?.nearest else { return "No traffic in range" }
        return "\(nearest.callsign) \(Units.distance(nauticalMiles: nearest.distanceNM, system: unitSystem).combined)"
    }

    private var accessibilityDescription: String {
        guard let snapshot = entry.snapshot else { return "No recent scan" }
        guard let nearest = snapshot.nearest else {
            return "No aircraft within \(Int(snapshot.radiusNM)) nautical miles"
        }
        var description = "\(nearest.callsign), \(Units.distance(nauticalMiles: nearest.distanceNM, system: unitSystem).spoken)"
        if nearest.isOnGround {
            description += ", on the ground"
        } else if let feet = nearest.altitudeFeet {
            description += ", \(Units.altitude(feet: Double(feet), system: unitSystem).spoken)"
        }
        if snapshot.age > 1800 {
            description += ", from \(Units.age(seconds: snapshot.age)) ago"
        }
        return description
    }
}

// MARK: - Previews

#Preview("Circular", as: .accessoryCircular) {
    TrafficCountWidget()
} timeline: {
    ScanEntry(date: .now, snapshot: .placeholder)
    ScanEntry(date: .now, snapshot: .empty)
    ScanEntry(date: .now, snapshot: nil)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    NearestAircraftWidget()
} timeline: {
    ScanEntry(date: .now, snapshot: .placeholder)
    ScanEntry(date: .now, snapshot: .empty)
}

#Preview("Corner", as: .accessoryCorner) {
    NearestAircraftWidget()
} timeline: {
    ScanEntry(date: .now, snapshot: .placeholder)
}

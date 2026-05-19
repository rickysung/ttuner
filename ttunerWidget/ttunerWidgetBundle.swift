import WidgetKit
import SwiftUI

@main
struct ttunerWidgetBundle: WidgetBundle {
    var body: some Widget {
        TtunerLauncherWidget()
    }
}

/// Minimal launcher widget — a tappable shortcut into the main app.
/// Exists so the widget extension target has a Widget to vend after
/// the Live Activity feature was retired. Future home-screen widgets
/// (current tuning, last-used preset, etc.) can join this bundle.
struct TtunerLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.ttuner.app.launcher",
                            provider: LauncherTimelineProvider()) { _ in
            LauncherView()
        }
        .configurationDisplayName("ttuner")
        .description("Tap to open the tuner.")
        .supportedFamilies([.systemSmall])
    }
}

private struct LauncherEntry: TimelineEntry {
    let date: Date
}

private struct LauncherTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry {
        LauncherEntry(date: .now)
    }
    func getSnapshot(in context: Context,
                     completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }
    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        // Static — never updates. The system reloads when the user
        // taps; nothing else needs to refresh.
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

private struct LauncherView: View {
    private let stable = Color(red: 0.32, green: 0.70, blue: 1.0)

    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.055, green: 0.060, blue: 0.075),
                Color(red: 0.005, green: 0.005, blue: 0.010)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(stable)
                    .shadow(color: stable.opacity(0.5), radius: 6)
                Text("ttuner")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("Tap to tune")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .containerBackground(.black, for: .widget)
    }
}

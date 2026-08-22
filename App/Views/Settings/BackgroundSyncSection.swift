#if os(iOS)
import SwiftUI
import UIKit

/// Shows what iOS has actually been doing with the background sync requests.
///
/// This pane answers a question that had no answer before it: "is background
/// sync broken, or has the system simply never chosen to wake us?" Those two
/// look identical from the outside, and only one of them is a bug.
///
/// The most useful line is usually the first. `BGAppRefreshTask` does not run at
/// all when Background App Refresh is switched off for the app, or off
/// system-wide, or while Low Power Mode is on — and none of those raise an
/// error. The app submits its request, the system accepts it, and nothing ever
/// happens.
struct BackgroundSyncSection: View {
    /// Re-read when the pane appears rather than observed: these change outside
    /// the app, in Settings and in a background process, so there is nothing
    /// here to observe.
    @State private var refreshStatus = UIApplication.shared.backgroundRefreshStatus
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var entries: [BackgroundSyncLog.Entry] = []
    @State private var showingLog = false

    var body: some View {
        Section {
            LabeledContent("Background App Refresh") {
                Label(refreshStatusText, systemImage: refreshStatusIcon)
                    .foregroundStyle(refreshStatus == .available ? Color.secondary : Color.orange)
            }

            if lowPowerMode {
                Label(
                    "Low Power Mode is on. iOS suspends background refresh entirely while it is.",
                    systemImage: "battery.25"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            LabeledContent("Last woken by iOS") {
                Text(lastLaunchText).foregroundStyle(.secondary)
            }

            if !entries.isEmpty {
                Button(showingLog ? "Hide activity" : "Show activity") {
                    showingLog.toggle()
                }
                if showingLog {
                    // Newest first: the question is nearly always about the most
                    // recent attempt.
                    ForEach(entries.reversed()) { entry in
                        LabeledContent {
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.event.rawValue)
                                    .font(.caption.weight(.medium))
                                Text(entry.date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Background sync")
        } footer: {
            Text(footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        refreshStatus = UIApplication.shared.backgroundRefreshStatus
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        entries = BackgroundSyncLog.entries
    }

    private var refreshStatusText: String {
        switch refreshStatus {
        case .available: return "On"
        case .denied: return "Off for Inkstone"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private var refreshStatusIcon: String {
        refreshStatus == .available ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var lastLaunchText: String {
        guard let date = BackgroundSyncLog.lastLaunch else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    private var footer: String {
        switch refreshStatus {
        case .available:
            // Said plainly, because the alternative is someone concluding the
            // feature is broken when it is working as iOS allows. The interval
            // in the picker above is a floor the system is free to ignore.
            return """
            iOS decides when a background sync runs. It learns from when you open \
            Inkstone, and it will not wake the app at all if you have force-quit it \
            from the app switcher. Expect a few runs a day, not one every interval.
            """
        case .denied:
            return "Turn it on in Settings › General › Background App Refresh, and again in Settings › Inkstone. Until then Inkstone can only sync while it is on screen."
        case .restricted:
            return "Background App Refresh is restricted on this device, by Screen Time or a device management profile. Inkstone can only sync while it is on screen."
        @unknown default:
            return ""
        }
    }
}
#endif

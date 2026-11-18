import SwiftUI
import os

/// How the screen is physically shaped right now, for devices that fold
/// (iPhone Duo).
///
/// Read from the system's **division** reserved region — the strip over the
/// crease that nothing important should sit across — plus the hinge status.
/// Apple's guidance is to lay out from reserved regions and use the hinge only
/// to decide behaviour, never raw angles, so that is all this looks at.
enum DevicePosture: Equatable {
    /// Flat: an ordinary phone, the outer screen, or the inner screen fully open.
    case flat
    /// Partly folded with a crease through the view. `crease` is in the
    /// reader's coordinate space; `isHorizontal` means the crease runs left to
    /// right (top and bottom halves) — the inner screen held upright and bent
    /// like a laptop. Otherwise it runs top to bottom (a book).
    case bent(crease: CGRect, isHorizontal: Bool)

    var isBent: Bool { if case .bent = self { true } else { false } }
}

private struct DevicePostureKey: EnvironmentKey {
    static let defaultValue: DevicePosture = .flat
}

extension EnvironmentValues {
    var devicePosture: DevicePosture {
        get { self[DevicePostureKey.self] }
        set { self[DevicePostureKey.self] = newValue }
    }
}

/// Measures the posture once at the root and hands it down.
///
/// Everything here is behind `iOS 27.1` availability; on older systems, and on
/// devices without a hinge, the posture is always `.flat` and nothing changes.
struct DevicePostureReader<Content: View>: View {
    @ViewBuilder var content: (DevicePosture) -> Content
    /// Partially open according to the hinge. The division region alone is
    /// what the layout follows; the hinge only confirms the device is bent
    /// rather than, say, a crease region reported while flat.
    @State private var hingePartiallyOpen = false

    private static var log: Logger { Logger(subsystem: "com.orris.inkstone", category: "Posture") }

    var body: some View {
        GeometryReader { proxy in
            let posture = Self.posture(in: proxy, hingePartiallyOpen: hingePartiallyOpen)
            content(posture)
                .environment(\.devicePosture, posture)
                .modifier(HingeObserver(partiallyOpen: $hingePartiallyOpen))
                #if DEBUG
                .onChange(of: posture, initial: true) { _, new in
                    Self.log.info("posture \(String(describing: new), privacy: .public) size \(proxy.size.debugDescription, privacy: .public) hingePartiallyOpen \(hingePartiallyOpen)")
                    Self.logRegions(proxy)
                }
                #endif
        }
    }

    static func posture(in proxy: GeometryProxy, hingePartiallyOpen: Bool) -> DevicePosture {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            let regions = proxy.reservedRegions(kind: .division)
            guard let crease = regions.first(where: \.isActive)?.frame, crease.width > 0 || crease.height > 0 else {
                return .flat
            }
            // A crease the full width of the view is horizontal.
            let isHorizontal = crease.width >= crease.height
            // Reserved but the hinge says flat: nothing is in the way of
            // reading across it, so keep the flat layout.
            return hingePartiallyOpen ? .bent(crease: crease, isHorizontal: isHorizontal) : .flat
        }
        #endif
        return .flat
    }

    #if DEBUG
    static func logRegions(_ proxy: GeometryProxy) {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            for kind in [ReservedRegion.Kind.division, .occlusion] {
                for region in proxy.reservedRegions(kind: kind, options: .includeInactive) {
                    log.info("region \(String(describing: kind), privacy: .public) frame \(region.frame.debugDescription, privacy: .public) active \(region.isActive)")
                }
            }
        }
        #endif
    }
    #endif
}

/// `onHingeChange`, where it exists.
private struct HingeObserver: ViewModifier {
    @Binding var partiallyOpen: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                let isPartial = new.hinge?.status == .partiallyOpen
                // Only on change: hinge updates can arrive often while the
                // device is moving, and each one would re-run the layout.
                if isPartial != partiallyOpen { partiallyOpen = isPartial }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

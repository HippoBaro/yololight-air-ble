/// Describes the values being shown, not just whether a Bluetooth link exists.
/// In particular, an optimistic edit must not be presented as verified state.
enum LightPresentation: Equatable {
    case unread, stale, editing, connecting, applying, verified

    var isVerified: Bool { self == .verified }

    var title: String {
        switch self {
        case .unread: "Not connected"
        case .stale: "Last known · Offline"
        case .editing: "Not applied"
        case .connecting: "Connecting…"
        case .applying: "Verifying…"
        case .verified: "Verified"
        }
    }

    var symbol: String {
        switch self {
        case .unread: "circle.dashed"
        case .stale: "clock.arrow.circlepath"
        case .editing: "pencil"
        case .connecting, .applying: "ellipsis.circle"
        case .verified: "checkmark.circle"
        }
    }

    var hint: String? {
        switch self {
        case .unread: "State unknown · Adjust to connect"
        case .stale: "Not current · Adjust to reconnect"
        case .editing: "Preview only · Not applied yet"
        case .connecting: "Reading actual state before applying…"
        case .applying: "Change not yet verified"
        case .verified: nil
        }
    }

    var accessibilityContext: String {
        switch self {
        case .unread: "Not connected. State unknown."
        case .stale: "Not connected. Last known value, not current state."
        case .editing: "Preview only. Not applied."
        case .connecting: "Connecting. Value not verified."
        case .applying: "Applying a change. Value not yet verified."
        case .verified: "Verified value."
        }
    }
}

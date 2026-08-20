import Foundation

/// Identifiable conformance for `URL`, used as `sheet(item:)` payload.
/// Lives in its own file so StorageView + StorageSettingsView can share
/// it without each redeclaring it.
extension URL: Identifiable {
    public var id: String { absoluteString }
}

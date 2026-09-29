import Foundation

// Wire types for the LocalSend protocol v2.2 receiver (see Docs/BOOKDROP.md
// for the endpoints and the spec link). Field names ARE the wire format —
// the coding keys below are deliberate; don't "tidy" them.

/// The peer/device announcement — both directions of discovery carry this.
struct LocalSendDevice: Codable, Equatable {
    var alias: String
    var version: String
    var deviceModel: String?
    /// mobile | desktop | web | headless | server
    var deviceType: String?
    var fingerprint: String
    var port: Int
    /// http | https — wire key is "protocol".
    var protocolField: String
    var download: Bool?

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download
        case protocolField = "protocol"
    }

    static func mock() -> LocalSendDevice {
        LocalSendDevice(
            alias: "Test", version: "2.2", deviceModel: nil, deviceType: "mobile",
            fingerprint: "f", port: 53317, protocolField: "http", download: false
        )
    }
}

/// One file offered in a prepare-upload request.
struct LocalSendFileMeta: Codable, Equatable {
    let id: String
    let fileName: String
    let size: Int64
    let fileType: String?
    let sha256: String?
    let preview: String?
    let metadata: FileMetadata?

    struct FileMetadata: Codable, Equatable {
        let modified: String?
        let accessed: String?
    }
}

/// POST /api/localsend/v2/prepare-upload request body.
struct LocalSendPrepareUpload: Codable {
    let info: LocalSendDevice
    let pin: String?
    let files: [String: LocalSendFileMeta]
}

/// prepare-upload's 200 response — sessionId plus a per-file token the
/// sender must echo on each upload.
struct LocalSendPrepareResponse: Codable {
    let sessionId: String
    let files: [String: String]
}

import Foundation
import UIKit

/// The sender half of the LocalSend protocol v2.2: find peers on the LAN,
/// ask permission, push files.
///
/// Discovery is a /24 unicast POST to the HTTP `/register` endpoint — the
/// same probe LocalSend's own senders make, and the reason a receiver needs
/// no entitlement: we dial OUT. A peer that answers 200 with a device DTO is
/// ours to send to.
///
/// Concurrency: URLSession does the I/O, completion handlers hop to the main
/// actor, so published state is MainActor-isolated and the transfer sequence
/// reads linearly.
/// One peer discovered on the LAN. Top-level (not nested in the @MainActor
/// sender) so the nonisolated scan probes can build it off the main actor.
struct Peer: Identifiable, Equatable {
    let id: String
    let fingerprint: String
    var alias: String
    var deviceModel: String?
    var deviceType: String?
    var host: String
    var port: Int

    init(fingerprint: String, alias: String, deviceModel: String?, deviceType: String?, host: String, port: Int) {
        self.id = fingerprint
        self.fingerprint = fingerprint
        self.alias = alias
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.host = host
        self.port = port
    }

    var baseURL: URL? { URL(string: "http://\(host):\(port)") }

    var displayKind: String {
        switch deviceType {
        case "desktop": return "Computer"
        case "mobile": return "Phone or tablet"
        case "web": return "Browser"
        case "headless": return "Device"
        case "server": return "Server"
        default: return "Device"
        }
    }
}

/// One file to hand over. The URL must stay readable for the whole
/// transfer: pass Documents/ files or a temp copy cleaned up by the
/// caller after completion.
struct SendItem {
    let url: URL
    let fileName: String
    /// A LocalSend "fileType" — the receiver may filter on it.
    var fileType: String?
}

@MainActor
final class LocalSendSender: ObservableObject {
    static let shared = LocalSendSender()

    // MARK: - Published state

    enum Phase: Equatable {
        case idle
        case scanning
        case sending
        case completed(String)
        case failed(String)
    }

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?

    /// Whether the scan can run at all: LocalSend is a LAN protocol, so
    /// off Wi-Fi there is nothing to find and the send button disables.
    var canSend: Bool { Self.wifiSubnet() != nil }

    /// Progress for the in-flight transfer: which file, and how much of the
    /// whole batch is through.
    @Published private(set) var progress = Progress()

    private var scanTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    /// Set true by the cancel path; a cancel mid-upload must not be reported
    /// as a failure, it must simply stop.
    private var cancelled = false

    private init() {}

    // MARK: - Discovery

    /// Scans this Wi-Fi's /24 for peers. Cheap: 254 short POSTs, capped at
    /// 48 in flight, so a normal LAN answers in about a second.
    func scan() {
        guard let subnet = Self.wifiSubnet() else {
            lastError = "Not connected to Wi-Fi"
            phase = .failed("Not connected to Wi-Fi")
            return
        }
        scanTask?.cancel()
        peers = []
        lastError = nil
        phase = .scanning
        scanTask = Task { [weak self] in
            let found = await Self.probeSubnet(subnet)
            guard !Task.isCancelled, let self else { return }
            self.peers = found
            self.phase = .idle
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        if case .scanning = phase { phase = .idle }
    }

    /// POST /register at each address of the subnet; the 200 body is the
    /// peer's DTO. Nonisolated so the probes run off the main actor.
    private nonisolated static func probeSubnet(_ subnet: String) async -> [Peer] {
        let concurrency = 48
        var found: [Peer] = []
        await withTaskGroup(of: [Peer]?.self) { group in
            var nextHost = 1
            func addNext() {
                guard nextHost <= 254 else { return }
                let host = "\(subnet).\(nextHost)"
                nextHost += 1
                group.addTask { await probe(host: host) }
            }
            for _ in 0..<concurrency where nextHost <= 254 { addNext() }
            while let result = await group.next() {
                if let peer = result { found.append(peer) }
                addNext()
            }
        }
        return found
    }

    private nonisolated static func probe(host: String) async -> Peer? {
        for port in peerPorts {
            guard let endpoint = URL(string: "http://\(host):\(port)/api/localsend/v2/register") else { continue }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 0.8
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(deviceDTO())
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let device = try? JSONDecoder().decode(LocalSendDevice.self, from: data),
                      device.fingerprint != fingerprint()
                else { continue }
                // The DTO's own port is where the peer actually serves: the
                // receiver binds the first free port in the range, and 53317
                // was only the door we knocked on.
                let port = device.port > 0 ? device.port : port
                return Peer(
                    fingerprint: device.fingerprint,
                    alias: device.alias,
                    deviceModel: device.deviceModel,
                    deviceType: device.deviceType,
                    host: host,
                    port: port
                )
            } catch let error as URLError where error.code == .timedOut {
                // Silent host (no ARP reply / filtered): no point knocking on
                // the other ten doors of a house that isn't there.
                return nil
            } catch {
                // Refused/closed port → the host is alive; try its next port.
                continue
            }
        }
        return nil
    }

    // MARK: - Send

    /// Clears published state when a fresh send screen opens — the transfer
    /// screens come and go on top of a long-lived singleton, and a stale
    /// failure from last time must not greet the next attempt.
    func reset() {
        phase = .idle
        lastError = nil
    }

    /// Sends every file in one session: prepare-upload, then one POST /upload
    /// per file, echoing the token prepare returned.
    func send(files: [SendItem], to peer: Peer, pin: String? = nil) {
        guard !files.isEmpty else { return }
        guard let base = peer.baseURL else {
            finishFailed("Bad address for \(peer.alias)")
            return
        }
        cancelled = false
        progress = Progress(totalUnitCount: Int64(files.count))
        phase = .sending
        sendTask = Task { @MainActor in
            await sendFiles(files, to: peer, base: base, pin: pin)
        }
    }

    /// The LocalSend default range, in probe order. A peer that moved keeps
    /// answering on 53317; one that didn't is found by trying each.
    private static let peerPorts = Array(53317...53327)

    func cancelSend() {
        cancelled = true
        sendTask?.cancel()
        sendTask = nil
        if case .sending = phase { phase = .idle }
    }

    private func sendFiles(_ items: [SendItem], to peer: Peer, base: URL, pin: String?) async {
        // prepare-upload: ids map files to the tokens prepare hands back.
        var metas: [(id: String, item: SendItem, meta: LocalSendFileMeta)] = []
        for item in items {
            let id = UUID().uuidString
            let size = (try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int64) ?? 0
            metas.append((id, item, LocalSendFileMeta(
                id: id,
                fileName: item.fileName,
                size: size,
                fileType: item.fileType,
                sha256: nil,
                preview: nil,
                metadata: nil
            )))
        }
        let metaDictionary = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta) })
        let prepareBody = LocalSendPrepareUpload(info: Self.deviceDTO(), pin: pin, files: metaDictionary)

        var prepareRequest = URLRequest(url: base.appendingPathComponent("api/localsend/v2/prepare-upload"))
        prepareRequest.httpMethod = "POST"
        prepareRequest.timeoutInterval = 20
        prepareRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        prepareRequest.httpBody = try? JSONEncoder().encode(prepareBody)

        let prepared: LocalSendPrepareResponse
        do {
            let (data, response) = try await URLSession.shared.data(for: prepareRequest)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            switch http.statusCode {
            case 200:
                prepared = try JSONDecoder().decode(LocalSendPrepareResponse.self, from: data)
            case 403:
                finishFailed("\(peer.alias) declined the transfer")
                return
            case 409:
                finishFailed("\(peer.alias) is busy with another transfer")
                return
            default:
                finishFailed("\(peer.alias) refused (HTTP \(http.statusCode))")
                return
            }
        } catch {
            finishFailed("Could not reach \(peer.alias)")
            return
        }

        // Upload each file in order, reporting batch progress as we go.
        for (index, entry) in metas.enumerated() {
            if cancelled { phase = .idle; return }
            guard let token = prepared.files[entry.id] else {
                finishFailed("\(peer.alias) gave no token for \(entry.item.fileName)")
                return
            }
            await upload(entry.item, id: entry.id, token: token, session: prepared.sessionId, to: base, peer: peer)
            if cancelled { phase = .idle; return }
            progress.completedUnitCount = Int64(index + 1)
        }
        phase = .completed(items.count == 1
            ? "Sent \(items[0].fileName) to \(peer.alias)"
            : "Sent \(items.count) files to \(peer.alias)")
    }

    /// One POST /upload, body = the file's bytes, streamed off disk.
    private func upload(
        _ item: SendItem,
        id: String,
        token: String,
        session: String,
        to base: URL,
        peer: Peer
    ) async {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: item.url.path))
        let size = (attributes?[.size] as? Int64) ?? 0
        guard let stream = InputStream(url: item.url) else {
            finishFailed("Could not read \(item.fileName)")
            return
        }
        stream.open()
        defer { stream.close() }

        var request = URLRequest(url: base.appendingPathComponent("api/localsend/v2/upload"))
        request.httpMethod = "POST"
        request.httpBodyStream = stream
        request.timeoutInterval = 3600 // a 700 MB book on slow Wi-Fi is minutes
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        // The session/file/token ride on the query string, as the spec's
        // upload endpoint declares.
        if var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
            components.queryItems = [
                URLQueryItem(name: "sessionId", value: session),
                URLQueryItem(name: "fileId", value: id),
                URLQueryItem(name: "token", value: token)
            ]
            if let rebuilt = components.url { request.url = rebuilt }
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                finishFailed("\(peer.alias) did not accept \(item.fileName)")
                return
            }
            switch http.statusCode {
            case 200:
                return
            case 403, 409:
                finishFailed("\(peer.alias) rejected \(item.fileName) (HTTP \(http.statusCode))")
            default:
                finishFailed("\(item.fileName) failed (HTTP \(http.statusCode))")
            }
        } catch {
            finishFailed("\(item.fileName) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Identity

    private nonisolated static func deviceDTO() -> LocalSendDevice {
        LocalSendDevice(
            alias: UIDevice.current.name,
            version: "2.2",
            deviceModel: deviceModelString(),
            deviceType: "mobile",
            fingerprint: fingerprint(),
            port: 0,
            protocolField: "http",
            download: false
        )
    }

    private nonisolated static func deviceModelString() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    /// The SAME fingerprint the receiver publishes: a peer must not see us
    /// as a second device in its own list.
    private nonisolated static func fingerprint() -> String {
        let key = "bookDropFingerprint"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString + UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: - Network context

    /// The Wi-Fi interface's first three octets ("192.168.1"), or nil off
    /// Wi-Fi — LocalSend is a LAN protocol, so scanning elsewhere is noise.
    private nonisolated static func wifiSubnet() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let interface = pointer.pointee
            defer { cursor = interface.ifa_next }
            guard String(cString: interface.ifa_name) == "en0",
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            // sockaddr_in: sin_len, sin_family occupy struct bytes 0…2, and
            // sa_data begins right after them — so sin_port is sa_data[0…2]
            // and sin_addr (4 bytes) is sa_data[2…6].
            let bytes = UnsafeRawPointer(address.pointee.sa_data)
                .assumingMemoryBound(to: UInt8.self)
            let octets = (2..<6).map { bytes[$0] }
            if octets[0] != 127 {
                return octets.dropLast().map { String($0) }.joined(separator: ".")
            }
        }
        return nil
    }

    private func finishFailed(_ message: String) {
        lastError = message
        phase = .failed(message)
    }
}

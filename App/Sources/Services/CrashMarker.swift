import Darwin
import Foundation

/// Names the killer. The 2026-10-23 device log shows the process dying in
/// the background while the audio I/O was LIVE and generation mid-flight —
/// every in-app log line was healthy right up to the cut. The two remaining
/// causes need different fixes:
///
///  - **a crash** (Swift runtime trap → SIGTRAP, Obj-C exception → SIGABRT,
///    bad memory → SIGSEGV/SIGBUS…) — fixable in code once named;
///  - **a system kill** — jetsam for memory (SIGKILL, uncatchable), or a
///    suspended process purged later. Needs footprint reduction, not code
///    paths.
///
/// This marker writes one byte-level line the instant a fatal signal or an
/// uncaught exception lands, and replays it into LogStore at the next
/// launch. A fresh relaunch with NO marker line is itself the verdict:
/// kill, not crash — jetsam's SIGKILL is precisely what cannot be caught.
///
/// The signal path is async-signal-safe by construction: the marker path
/// and every per-signal message are pre-built byte arrays at install time;
/// the handler only `open`/`write`/`close`s. No allocation, no locks, no
/// Objective-C, no Swift runtime entry points beyond array pointer access.
/// The crash timestamp is the marker file's mtime — formatting a time in a
/// signal handler is not safe, so the content carries only the cause.
enum CrashMarker {

    /// Documents/crash-marker.txt — beside the persisted log, so it
    /// survives the kill and surfaces in the same Logs-tab export.
    private static let fileName = "crash-marker.txt"

    private static let signals: [Int32: String] = [
        SIGSEGV: "SIGSEGV", SIGABRT: "SIGABRT", SIGBUS: "SIGBUS",
        SIGILL: "SIGILL", SIGFPE: "SIGFPE", SIGTRAP: "SIGTRAP"
    ]

    /// Pre-built at install: path bytes (NUL-terminated) and message bytes
    /// per signal. Written once, read-only afterwards — the handler may not
    /// allocate.
    private static var markerPathBytes: [CChar] = []
    private static var messageBytes: [Int32: [UInt8]] = [:]

    /// Install the handlers and replay any verdict the previous launch
    /// left. Call once, as early as App.init — anything that crashes before
    /// this point is invisible to the marker (acceptable: engine and
    /// playback code all load far later).
    static func installAndReplay() {
        let url = Self.markerURL

        // Replay first, before installing anything: the previous launch's
        // verdict is the payload of this whole exercise.
        if let prior = try? String(contentsOf: url, encoding: .utf8) {
            let verdict = prior.trimmingCharacters(in: .whitespacesAndNewlines)
            if !verdict.isEmpty {
                Log.shared.error(
                    "PREVIOUS LAUNCH CRASHED — \(verdict.replacingOccurrences(of: "\n", with: " | ")). "
                        + "A relaunch with NO line like this is a system kill (jetsam/suspend-purge), not a crash"
                )
                try? FileManager.default.removeItem(at: url)
            }
        }

        markerPathBytes = Array(url.path.utf8CString)
        for (sig, name) in signals {
            messageBytes[sig] = Array("\(name)\n".utf8)
            signal(sig, crashSignalHandler)
        }
        NSSetUncaughtExceptionHandler(crashExceptionHandler)
    }

    private static var markerURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }
}

/// Async-signal-safe. Runs on an arbitrary thread with the crash in
/// progress; see the enum doc for the constraints that shaped it.
private func crashSignalHandler(_ sig: Int32) {
    let path = CrashMarker.markerPathBytesForHandler()
    if !path.isEmpty, let message = CrashMarker.messageBytesForHandler(sig) {
        path.withUnsafeBufferPointer { pathBuf in
            message.withUnsafeBufferPointer { msgBuf in
                let fd = open(pathBuf.baseAddress!, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                if fd >= 0 {
                    _ = write(fd, msgBuf.baseAddress!, msgBuf.count)
                    close(fd)
                }
            }
        }
    }
    // Restore the default disposition and re-raise so the system still
    // produces its own crash report — the marker supplements it, it does
    // not replace it.
    signal(sig, SIG_DFL)
    raise(sig)
}

/// The uncaught-exception context is NOT a signal context (it runs as a
/// normal call before the runtime aborts), so Foundation is allowed here.
/// The abort that follows lands in `crashSignalHandler`, which adds the
/// one-word SIGABRT line beside this detail — together they read
/// "NSException … / SIGABRT".
private func crashExceptionHandler(_ exception: NSException) {
    let detail = "NSException \(exception.name.rawValue): \(exception.reason ?? "no reason")\n"
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(CrashMarker.markerFileNameForHandler())
    let data = Data(detail.utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

/// Handler-side accessors. Plain static reads of already-initialized
/// storage; they exist so the handler body needs no enum-namespace
/// traversal beyond one call.
extension CrashMarker {
    fileprivate static func markerPathBytesForHandler() -> [CChar] { markerPathBytes }
    fileprivate static func messageBytesForHandler(_ sig: Int32) -> [UInt8]? { messageBytes[sig] }
    fileprivate static func markerFileNameForHandler() -> String { fileName }
}

// MARK: - Process memory (the jetsam numbers)

/// The two figures a jetsam diagnosis needs, read from the process itself.
/// Used by the background-transition snapshot and the 10 s background
/// vitals line: a footprint climbing toward the ceiling across the last
/// few vitals lines before a fresh relaunch IS the jetsam verdict.
enum ProcessMemory {

    /// Bytes the kernel bills this process for — the number the jetsam
    /// ceiling is compared against. `task_vm_info.phys_footprint` via
    /// `task_info`; the flavor literal 22 is TASK_VM_INFO (the C macro
    /// does not import into Swift).
    static func footprintBytes() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                task_info(mach_task_self_, 22, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint)
    }

    /// Bytes left before the jetsam ceiling closes on THIS process
    /// (`os_proc_available_memory`). Zero means "unavailable" — reported
    /// as nil so callers print a ? instead of a fake ceiling.
    static func availableBytes() -> Int? {
        let value = os_proc_available_memory_binding()
        return value == 0 ? nil : Int(value)
    }

    /// One compact log fragment: "mem 412MB footprint / 1180MB to ceiling".
    static func summary() -> String {
        let footprint = footprintBytes().map { Self.mb($0) } ?? "?"
        let available = availableBytes().map { Self.mb($0) } ?? "?"
        return "mem \(footprint)MB footprint / \(available)MB to ceiling"
    }

    private static func mb(_ bytes: Int) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }
}

/// `<os/proc.h>` is not imported by any Swift module; bind the symbol
/// directly. Return is `uint32_t` per the header.
@_silgen_name("os_proc_available_memory")
private func os_proc_available_memory_binding() -> UInt32

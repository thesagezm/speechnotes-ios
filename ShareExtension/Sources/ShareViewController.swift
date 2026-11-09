import UIKit
import SwiftUI
import UniformTypeIdentifiers
import SpeechLogic

/// The share-sheet entry point (native installs only — LiveContainer cannot
/// host app extensions, so LC users keep the extension-free channels
/// documented in ImportService).
///
/// Job: pull a URL (or a URL-bearing text) out of the share payload and hand
/// it to the containing app through the speechnotes:// scheme —
/// `speechnotes://import?url=…` lands in NotesListView.handleOpenURL, which
/// runs the full article importer (fetch → Readability → markdown → note).
/// Short plain texts ride `speechnotes://…?text=` as a verbatim note.
///
/// No App Group on purpose: the scheme needs no entitlement, and free-
/// account sideloading (SideStore) provisions extension entitlements
/// unreliably. The handoff itself tries `NSExtensionContext.open` first
/// (sanctioned, historically Today-widget-only), then the responder-chain
/// `openURL:` — iOS guarantees neither from a share extension — and when
/// both fail the sheet says so and copies the payload for the clipboard
/// importer ("⋯ → New note from clipboard").
final class ShareViewController: UIViewController {

    /// Longest text forwarded through the URL scheme. Percent-encoded this
    /// stays inside the custom-scheme URL length iOS honors reliably; a
    /// longer share falls back to the clipboard route.
    private static let schemeTextCap = 1200

    private let model = ShareStatusModel()

    /// Set once the handoff has a verdict — guards the completion against
    /// the timeout race (open's callback vs the 1.2s bound below).
    private var settled = false

    private lazy var statusController: UIHostingController<ShareStatusView> = {
        UIHostingController(rootView: ShareStatusView(model: model))
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        addChild(statusController)
        view.addSubview(statusController.view)
        statusController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusController.view.topAnchor.constraint(equalTo: view.topAnchor),
            statusController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        statusController.didMove(toParent: self)
        extractPayload { [weak self] payload in
            DispatchQueue.main.async {
                self?.handle(payload)
            }
        }
    }

    // MARK: - Payload extraction

    private enum Payload {
        case url(URL)
        case text(String)
    }

    private func extractPayload(_ completion: @escaping (Payload?) -> Void) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            completion(nil)
            return
        }
        let attachments = items.flatMap { $0.attachments ?? [] }

        // Safari's page share carries public.url. loadItem's delivery type
        // varies by sender (URL / NSURL / Data / String) — coerce them all.
        if let provider = attachments.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = Self.url(fromItem: item) {
                    completion(.url(url))
                    return
                }
                // Some senders tag text as a url attachment — the text
                // path still gets a say before giving up.
                if let text = Self.string(fromItem: item), !text.isEmpty {
                    completion(.text(text))
                    return
                }
                completion(nil)
            }
            return
        }

        if let provider = attachments.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = Self.string(fromItem: item) ?? ""
                completion(text.isEmpty ? nil : .text(text))
            }
            return
        }
        completion(nil)
    }

    private static func url(fromItem item: Any?) -> URL? {
        switch item {
        case let url as URL:
            return url
        case let string as String:
            return URL(string: string) ?? WebArticle.url(in: string)
        case let data as Data:
            guard let string = String(data: data, encoding: .utf8) else { return nil }
            return URL(string: string) ?? WebArticle.url(in: string)
        default:
            return nil
        }
    }

    private static func string(fromItem item: Any?) -> String? {
        switch item {
        case let string as String:
            return string
        case let data as Data:
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    // MARK: - Handoff

    private func handle(_ payload: Payload?) {
        switch payload {
        case .url(let url):
            // Web addresses only — a file or app-scheme URL has no
            // importer to land in (file shares go through Open-In).
            guard url.scheme == "http" || url.scheme == "https" else {
                fail("Only web links can be imported.")
                return
            }
            open(Self.articleURL(url), host: url.host ?? "link")
        case .text(let raw):
            // Text that IS a link shares as text on some senders — same
            // article importer as a page share. WebArticle.url(in:) is
            // deliberately strict (one token), so prose keeps its default:
            // a verbatim note.
            if let url = WebArticle.url(in: raw) {
                open(Self.articleURL(url), host: url.host ?? "link")
            } else if raw.count <= Self.schemeTextCap {
                open(Self.noteURL(raw), host: "note")
            } else {
                copyAndOfferRetry(
                    raw,
                    reason: "Text too long to hand off directly",
                    message: "It's copied. Open Speechnotes → ⋯ → New note from clipboard."
                )
            }
        case nil:
            fail("Nothing shareable here.")
        }
    }

    /// `speechnotes://import?url=…` — the Shortcuts/automation form of the
    /// article share, already handled by the app.
    private static func articleURL(_ url: URL) -> URL {
        var components = URLComponents()
        components.scheme = "speechnotes"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url!
    }

    /// `speechnotes://import?text=…` — lands as a verbatim note.
    private static func noteURL(_ text: String) -> URL {
        var components = URLComponents()
        components.scheme = "speechnotes"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url!
    }

    private func open(_ url: URL, host: String) {
        model.update(
            glyph: "arrow.up.forward.circle.fill",
            title: "Sending to Speechnotes",
            message: host == "note" ? "Preparing the note…" : "Fetching \(host)…"
        )
        let fallback: () -> Void = { [weak self] in
            guard let self, !self.settled else { return }
            self.settled = true
            if self.openViaResponderChain(url) {
                self.model.update(
                    glyph: "checkmark.circle.fill",
                    title: "Opening Speechnotes",
                    message: host == "note" ? "Your note is being created." : "The article will be imported there."
                )
                self.scheduleComplete()
            } else {
                self.copyAndOfferRetry(
                    url.absoluteString,
                    reason: "Couldn't open Speechnotes automatically",
                    message: "The link is copied. Open Speechnotes → ⋯ → New note from clipboard."
                )
            }
        }

        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    guard !self.settled else { return }
                    self.settled = true
                    self.model.update(
                        glyph: "checkmark.circle.fill",
                        title: "Opening Speechnotes",
                        message: host == "note" ? "Your note is being created." : "The article will be imported there."
                    )
                    self.scheduleComplete()
                } else {
                    fallback()
                }
            }
        }
        // open's completion is not contractually guaranteed to fire (the
        // API officially supports Today widgets) — bound the wait and try
        // the responder chain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: fallback)
    }

    /// UIApplication is off-limits in an extension; walking the responder
    /// chain reaches the real UIApplication and its `openURL:` — the
    /// long-standing escape hatch share extensions use. Returns whether
    /// someone along the chain claimed the selector, not whether iOS
    /// actually switched apps (nothing can promise that here).
    private func openViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    /// The honest-degradation path: copy the payload for the clipboard
    /// importer and tell the user exactly where to tap next. The sheet
    /// stays up with a Done button.
    private func copyAndOfferRetry(_ payload: String, reason: String, message: String) {
        settled = true
        UIPasteboard.general.string = payload
        model.update(
            glyph: "doc.on.clipboard.fill",
            title: reason,
            message: message,
            actionTitle: "Done",
            action: { [weak self] in self?.finish() }
        )
    }

    private func fail(_ message: String) {
        settled = true
        model.update(
            glyph: "exclamationmark.triangle.fill",
            title: "Speechnotes",
            message: message,
            actionTitle: "Done",
            action: { [weak self] in self?.finish() }
        )
    }

    private func scheduleComplete() {
        // Give iOS a beat to switch to the app; if it never does (cold
        // launch, system hiccup) the sheet still closes itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

/// The status card's state. A plain ObservableObject mutated from the
/// controller keeps the SwiftUI side dumb — no callbacks into UIKit, no
/// per-status view rebuilds of anything but this card.
@MainActor
private final class ShareStatusModel: ObservableObject {
    @Published var glyph = "waveform.circle.fill"
    @Published var title = "Speechnotes"
    @Published var message = "Preparing…"
    @Published var actionTitle: String?
    var action: (() -> Void)?

    nonisolated func update(
        glyph: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        // UIViewController callbacks arrive on main (loadItem completions
        // are explicitly hopped in viewDidLoad); the @MainActor class makes
        // that contract compiler-checked the same way WebArticleService
        // reconciles its main-arrival bridge callbacks.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.glyph = glyph
                self.title = title
                self.message = message
                self.actionTitle = actionTitle
                self.action = action
            }
        }
    }
}

private struct ShareStatusView: View {
    @ObservedObject var model: ShareStatusModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: model.glyph)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(model.title)
                .font(.headline)
            Text(model.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle = model.actionTitle {
                Button {
                    model.action?()
                } label: {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

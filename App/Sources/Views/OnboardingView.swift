import SwiftUI

/// First-launch onboarding: five swipeable pages (welcome → PDFs/OCR →
/// audiobooks → voices → pomodoro & stats), presented once via `hasOnboarded`
/// in SpeechnotesApp. Deliberately dependency-free — no environment objects,
/// no side effects at presentation (LiveContainer launch-crash hygiene):
/// every fact below is copy, never a query of a live store/model.
///
/// The v1.8.0 round folded the old "Start with a note" page into the welcome
/// page (its CTA was discoverable anyway) to make room for the Pomodoro &
/// Stats page without growing the flow past five pages (user request).
struct OnboardingView: View {
    /// Called when the user finishes (or skips) the flow.
    let onDone: () -> Void

    @State private var page = 0

    private let lastPage = 4

    var body: some View {
        ZStack {
            // Soft gradient backdrop.
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcomePage.tag(0)
                    pdfPage.tag(1)
                    audiobooksPage.tag(2)
                    voicesPage.tag(3)
                    pomodoroPage.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                // V7: the raw page dots are unlabeled to VoiceOver ("page 3
                // of 5", no context) — one announcement carries what changed.
                .accessibilityLabel("Page \(page + 1) of \(lastPage + 1)")

                Button {
                    Haptics.success()
                    onDone()
                } label: {
                    Text(page == lastPage ? "Get started" : "Skip")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(page == lastPage ? Color.accentColor : Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(page == lastPage ? Color.white : Color.primary)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform")
                // V7: 72pt fixed glyph, no Dynamic Type cap — scaled + capped
                // so an accessibility text size doesn't blow the layout.
                .font(.system(size: 72, weight: .light))
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .frame(maxWidth: 88, maxHeight: 88)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Speechnotes")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Write it, then hear it read aloud — completely offline. Tap + to write your first note, or import a book and read along.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    private var pdfPage: some View {
        VStack(spacing: 18) {
            Spacer()
            pageIcon("doc.text.viewfinder")
            Text("Scanned PDFs become readable")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Import a PDF from the ⋯ menu on the Books tab. Pages with a real text layer read directly; camera scans (CamScanner-style watermarks included) get OCR automatically — or force OCR per book from the reader.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
    }

    private var audiobooksPage: some View {
        VStack(spacing: 18) {
            Spacer()
            pageIcon("headphones")
            Text("Audiobooks, chapters and all")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                featureRow("books.vertical", "M4B, MP3, Opus and Ogg files")
                featureRow("list.number", "Chapter list, ±15 s skips, speed and a sleep timer")
                featureRow("arrow.clockwise", "Your place is kept — backgrounding, quitting and re-opening all resume where you stopped")
            }
            .padding(.horizontal, 34)
            Spacer()
            Spacer()
        }
    }

    private var voicesPage: some View {
        VStack(spacing: 22) {
            Spacer()
            pageIcon("person.wave.2.fill")
            Text("Pick a voice you like")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                featureRow("apple.logo", "Apple system voice — works instantly")
                featureRow("cpu", "Kokoro — neural, 28 voices (High ~341 MB or Compact ~92 MB)")
                featureRow("globe", "Supertonic — best quality, 31 languages (~399 MB)")
            }
            .padding(.horizontal, 34)
            Text("Voices are managed later in Settings → Speech Settings. Everything runs on your device; nothing is uploaded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    private var pomodoroPage: some View {
        VStack(spacing: 18) {
            Spacer()
            pageIcon("timer")
            Text("Focus, and see it add up")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                featureRow("timer", "Pomodoro on the Stats tab — Structured work/break cycles, Flowmodoro (bank break minutes as you focus), or a free timer")
                featureRow("chart.bar.xaxis", "Every listening minute lands in Stats: streaks, goals and per-book time")
                featureRow("bell", "A gentle banner keeps a running session present while you read or listen")
            }
            .padding(.horizontal, 34)
            Spacer()
            Spacer()
        }
    }

    /// V7 treatment for the big page glyphs: scale with Dynamic Type (capped
    /// so the layout survives accessibility sizes) and keep them out of the
    /// VoiceOver order — the heading beside them already carries the meaning.
    private func pageIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 56, weight: .light))
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            .frame(maxWidth: 72, maxHeight: 72)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }

    private func featureRow(_ icon: String, _ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 26)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

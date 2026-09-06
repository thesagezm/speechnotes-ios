import SwiftUI

/// First-launch onboarding: three swipeable pages (welcome → voices →
/// get started), presented once via `hasOnboarded` in SpeechnotesApp.
/// Deliberately dependency-free — no environment objects, no side effects
/// at presentation (LiveContainer launch-crash hygiene).
struct OnboardingView: View {
    /// Called when the user finishes (or skips) the flow.
    let onDone: () -> Void

    @State private var page = 0

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
                    voicesPage.tag(1)
                    startPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    Haptics.success()
                    onDone()
                } label: {
                    Text(page == 2 ? "Get started" : "Skip")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(page == 2 ? Color.accentColor : Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(page == 2 ? Color.white : Color.primary)
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
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Speechnotes")
                .font(.largeTitle.bold())
            Text("Write it, then hear it read aloud — completely offline.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    private var voicesPage: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Pick a voice you like")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 14) {
                featureRow("apple.logo", "Apple system voice — works instantly")
                featureRow("cpu", "Kokoro — neural, 28 voices (small ~177 MB, full ~341 MB)")
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

    private var startPage: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "square.and.pencil")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Start with a note")
                .font(.title2.bold())
            Text("Tap + to write your first note, or import a text, markdown or PDF file from the ⋯ menu. Tap play and follow along.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    private func featureRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 26)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.subheadline)
        }
    }
}

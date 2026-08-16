import SwiftUI

struct ContentView: View {
    @State private var showingHello = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Speechnotes iOS")
                .font(.title.bold())
            Text("Phase 0 — build pipeline works")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Say hello") {
                showingHello = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .alert("Hello from the cloud build!", isPresented: $showingHello) {
            Button("OK", role: .cancel) {}
        }
    }
}

#Preview {
    ContentView()
}

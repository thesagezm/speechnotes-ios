import SwiftUI

struct ImportVoicesView: View {
    var body: some View {
        Form {
            Section("Import ONNX Voices") {
                Text("Pick .npz voice packs from Files or the web. Volatile packs <500 MB are copied to the app's Documents/Models and registered for Kokoro.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Link("Kokoro voices <500 MB (HuggingFace)", destination: URL(string: "https://huggingface.co/collections/mlalma/kokoro-voices")!)
                Link("MLX models · GitHub", destination: URL(string: "https://github.com/mlalma")!)
            }
        }
        .navigationTitle("Import Voices")
    }
}

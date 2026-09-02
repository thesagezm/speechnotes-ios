import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Photos picker bridge: presents `UIImagePickerController`, returns the
/// chosen image's raw bytes + extension to a callback. Always re-encodes
/// to PNG so the file in the cache is portable.
struct ImagePicker: UIViewControllerRepresentable {
    let completion: (Data, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Data, String) -> Void
        init(completion: @escaping (Data, String) -> Void) {
            self.completion = completion
        }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.pngData() {
                completion(data, "png")
            }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

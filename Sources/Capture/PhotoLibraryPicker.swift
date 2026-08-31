#if os(iOS)
import SwiftUI
import PhotosUI

/// WeChat-style zero-permission photo capture: the system picker (PHPickerViewController)
/// runs out-of-process and shows the library newest-first, so tapping the first thumbnail
/// selects the latest photo without any authorization prompt.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    /// Called with the picked image, or nil when the user cancels.
    let onImage: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImage: (UIImage?) -> Void

        init(onImage: @escaping (UIImage?) -> Void) {
            self.onImage = onImage
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                onImage(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [onImage] object, _ in
                DispatchQueue.main.async {
                    onImage(object as? UIImage)
                }
            }
        }
    }
}
#endif

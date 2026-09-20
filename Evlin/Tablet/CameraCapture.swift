import SwiftUI
import UIKit

/// Direct camera capture for a kid's task-evidence photo. Falls back to the
/// photo library when no camera exists (the Simulator, mainly — this is
/// what actually makes the flow testable without a device) rather than
/// presenting a broken picker.
struct CameraCapture: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

enum PhotoCompression {
    /// Downsamples to a reasonable max dimension and re-encodes as JPEG — a
    /// full-resolution photo (10+MB on a modern phone) is wasted upload time
    /// and R2 storage for evidence a parent just glances at. Mirrors
    /// downsampledAvatar's approach (see FamilyData.swift) at a size that
    /// still reads clearly as a photo of homework/a chore.
    static func compress(_ image: UIImage, maxDimension: CGFloat = 1600, quality: CGFloat = 0.6) -> Data? {
        let size = image.size
        let longer = max(size.width, size.height)
        let scale = longer > maxDimension ? maxDimension / longer : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
    }
}

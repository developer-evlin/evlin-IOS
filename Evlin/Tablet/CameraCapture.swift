import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

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
    struct Encoded { let data: Data; let contentType: String; let ext: String }

    /// A kid's task photo, ready to upload: at most 1600 px, HEIC (about
    /// half a JPEG's size at the same look; the parent's iPhone shows it
    /// natively), JPEG where HEIC can't be written. Drawn afresh, so the
    /// camera's metadata (location included) isn't carried over.
    static func encodeForUpload(_ image: UIImage, maxDimension: CGFloat = 1600) -> Encoded? {
        let size = image.size
        let longer = max(size.width, size.height)
        let scale = longer > maxDimension ? maxDimension / longer : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let cg = resized.cgImage {
            let data = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
                if CGImageDestinationFinalize(dest), data.length > 0 {
                    return Encoded(data: data as Data, contentType: "image/heic", ext: "heic")
                }
            }
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.6) else { return nil }
        return Encoded(data: jpeg, contentType: "image/jpeg", ext: "jpg")
    }

    /// Downsamples to a reasonable max dimension and re-encodes as JPEG — a
    /// full-resolution photo (10+MB on a modern phone) is wasted upload time
    /// and R2 storage for evidence a parent just glances at. 1600px still
    /// reads clearly as a photo of homework/a chore.
    static func compress(_ image: UIImage, maxDimension: CGFloat = 1600, quality: CGFloat = 0.6) -> Data? {
        let size = image.size
        let longer = max(size.width, size.height)
        let scale = longer > maxDimension ? maxDimension / longer : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        // Scale 1: `target` is in pixels. The renderer's default is the
        // screen's scale, which made a "1600px" photo 4800px on a 3x phone.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
    }
}

import SwiftUI

/// A check-in's photo, from this device's GoalProof folder or the web.
struct ProofPhoto: View {
    var ref: String
    var cornerRadius: CGFloat = 10

    var body: some View {
        if ref.hasPrefix("http") {
            RemotePhoto(urlString: ref, cornerRadius: cornerRadius)
        } else if let url = GoalProof.url(ref), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(TemplateStyle.tile)
        }
    }
}

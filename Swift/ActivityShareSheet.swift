import SwiftUI
import UIKit

/// Native UIActivityViewController bridge for sharing a downloaded media file.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

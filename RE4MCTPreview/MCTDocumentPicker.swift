import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MCTDocumentPickerResult {
    case picked(URL)
    case failed(String)
    case cancelled
}

/// A direct UIDocumentPicker wrapper using public.data and copy-import mode.
/// The app validates the .mct extension after the user confirms the selection.
struct MCTDocumentPicker: UIViewControllerRepresentable {
    let onPick: (MCTDocumentPickerResult) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (MCTDocumentPickerResult) -> Void

        init(onPick: @escaping (MCTDocumentPickerResult) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onPick(.failed("文件選擇器沒有回傳任何檔案 URL。"))
                return
            }
            onPick(.picked(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(.cancelled)
        }
    }
}

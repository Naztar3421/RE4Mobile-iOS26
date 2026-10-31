import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MCTDocumentPickerResult {
    case picked(URL)
    case failed(String)
    case cancelled
}

/// A direct UIDocumentPicker wrapper.
/// The default remains public.data + copy-import mode for MCT and ordinary data files.
/// Callers may use public.item for extensionless or provider-typed files such as dyld caches.
struct MCTDocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let asCopy: Bool
    let onPick: (MCTDocumentPickerResult) -> Void

    init(
        contentTypes: [UTType] = [.data],
        asCopy: Bool = true,
        onPick: @escaping (MCTDocumentPickerResult) -> Void
    ) {
        self.contentTypes = contentTypes
        self.asCopy = asCopy
        self.onPick = onPick
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: asCopy
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

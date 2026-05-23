import SwiftUI

@main
struct DarwinScanApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { ScanDocument() }) { config in
            ContentView(document: config.document)
        }
        .commands {
            // File > Save naturally handled by DocumentGroup; nothing extra
            // for now. Keep the menu surface minimal until features land.
        }
    }
}

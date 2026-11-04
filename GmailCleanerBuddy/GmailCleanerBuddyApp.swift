import SwiftUI

@main
struct GmailCleanerBuddyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environment(model)
        }
    }
}

import SwiftUI

@main
struct HomeScannerApp: App {
    @State private var store = HomeStore()
    @State private var pinBoard = PinBoard()
    @State private var assistant = HomeAssistantSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(pinBoard)
                .environment(assistant)
                .task(id: assistant.generation) {
                    pinBoard.use(
                        provider: assistant.makeProvider(),
                        live: assistant.isConfigured,
                        endpoint: assistant.endpoint
                    )
                }
        }
    }
}

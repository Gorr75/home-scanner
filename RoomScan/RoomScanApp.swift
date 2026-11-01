import SwiftUI

@main
struct RoomScanApp: App {
    @State private var store = HomeStore()
    @State private var pinBoard = PinBoard()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(pinBoard)
        }
    }
}

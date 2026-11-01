import RoomPlan

enum LiDARSupport {
    static var canScan: Bool {
        RoomCaptureSession.isSupported
    }

    static var unavailableReason: String {
        #if targetEnvironment(simulator)
        "This simulator has no LiDAR scanner. Open the sample apartment to use the 3D model and floor plan. Scanning needs a physical iPhone or iPad Pro with LiDAR."
        #else
        "This device has no LiDAR scanner. Saved homes and the sample apartment still open. Scanning needs an iPhone or iPad Pro with LiDAR."
        #endif
    }
}

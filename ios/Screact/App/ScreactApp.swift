import Network
import SwiftUI

@main
struct ScreactApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    @State private var pathMonitor: NWPathMonitor?
    @State private var lastPathSatisfied = true

    var body: some View {
        ProductionScreen(
            state: viewModel.productionState,
            savedHost: viewModel.savedHost,
            savedPort: viewModel.savedPort,
            hasTrustedPc: viewModel.hasTrustedPc,
            cameraPermissionPermanentlyDenied: viewModel.productionState.camera == .permissionDenied,
            preview: { CameraPreviewView(session: viewModel.cameraSession.session) },
            onRequestCameraPermission: viewModel.requestCameraPermission,
            onOpenSystemSettings: openSystemSettings,
            onRetryCamera: viewModel.retryCamera,
            onConnect: { host, port, token in viewModel.connect(host: host, portText: port, pairingToken: token) },
            onStartAutoPairing: viewModel.startAutoPairing,
            onCancelAutoPairing: viewModel.cancelAutoPairing,
            onCancelConnection: viewModel.disconnect,
            onDisconnect: viewModel.disconnect,
            onRetryNow: viewModel.retryNow,
            onChangeConnectionSettings: viewModel.changeConnectionSettings,
            onForgetTrustedPc: viewModel.forgetTrustedPc
        )
        .ignoresSafeArea()
        .onAppear {
            viewModel.startCameraIfAuthorized()
            startNetworkMonitor()
        }
        .onDisappear {
            pathMonitor?.cancel()
            pathMonitor = nil
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// iOS equivalent of Android's default-network callback: nudge the WebSocket client to
    /// reconnect/pause when connectivity flips.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                if satisfied == lastPathSatisfied { return }
                lastPathSatisfied = satisfied
                if satisfied { viewModel.onNetworkAvailable() } else { viewModel.onNetworkLost() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.nxtend.team35.yubiboard.netmonitor"))
        pathMonitor = monitor
    }
}

import SwiftUI

/// SwiftUI port of Android's ProductionScreen (the character-redesign production UI). Reproduces the
/// watercolor guide panel, the character mascot, the connection form, calibration progress, and the
/// help sheet, driven by the same ProductionUiState -> visualState mapping.
enum GuideColors {
    static let ink = Color(red: 0x4A / 255, green: 0x4A / 255, blue: 0x4A / 255)
    static let bodyInk = Color(red: 0x68 / 255, green: 0x66 / 255, blue: 0x66 / 255)
    static let button = Color(red: 0x68 / 255, green: 0x66 / 255, blue: 0x66 / 255)
    static let field = Color(red: 0xFF / 255, green: 0xFD / 255, blue: 0xFD / 255)
    static let error = Color(red: 0x9B / 255, green: 0x3E / 255, blue: 0x3A / 255)
    static let previewBackground = Color(red: 0xD8 / 255, green: 0xD8 / 255, blue: 0xD8 / 255)
}

struct ProductionScreen<Preview: View>: View {
    let state: ProductionUiState
    let savedHost: String
    let savedPort: Int
    let hasTrustedPc: Bool
    let cameraPermissionPermanentlyDenied: Bool
    @ViewBuilder let preview: () -> Preview

    let onRequestCameraPermission: () -> Void
    let onOpenSystemSettings: () -> Void
    let onRetryCamera: () -> Void
    let onConnect: (String, String, String) -> String?
    let onCancelConnection: () -> Void
    let onDisconnect: () -> Void
    let onRetryNow: () -> Void
    let onChangeConnectionSettings: () -> Void
    let onForgetTrustedPc: () -> Void

    @State private var host: String = ""
    @State private var port: String = ""
    @State private var token: String = ""
    @State private var formError: String?
    @State private var showHelp = false
    @State private var initialized = false

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height >= geo.size.width
            Group {
                if portrait {
                    VStack(spacing: 0) {
                        previewPane.frame(maxWidth: .infinity).layoutPriority(0.85)
                        guidePanel.frame(maxWidth: .infinity).layoutPriority(1.15)
                    }
                } else {
                    HStack(spacing: 0) {
                        previewPane.frame(maxHeight: .infinity).layoutPriority(2.1)
                        guidePanel.frame(maxHeight: .infinity).layoutPriority(1)
                    }
                }
            }
            .background(GuideColors.previewBackground)
        }
        .onAppear {
            guard !initialized else { return }
            host = savedHost.isEmpty ? "127.0.0.1" : savedHost
            port = String(savedPort)
            initialized = true
        }
        .sheet(isPresented: $showHelp) { helpSheet }
    }

    private var previewPane: some View {
        ZStack {
            GuideColors.previewBackground
            preview()
        }
    }

    // MARK: - Guide panel

    private var guidePanel: some View {
        ZStack {
            Image("production_watercolor_background")
                .resizable()
                .scaledToFill()
                .clipped()
            Color.white.opacity(0.0)

            VStack(spacing: 12) {
                panelContent
                if let notice = state.notice, !notice.isEmpty {
                    feedbackText(notice)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack {
                    Spacer()
                    helpButton
                }
                Spacer()
            }
            .padding(8)
        }
        .background(Color.white)
        .clipped()
    }

    @ViewBuilder
    private var panelContent: some View {
        switch state.visualState {
        case .cameraPermission: cameraPermissionPanel
        case .cameraError: cameraErrorPanel
        case .connectionForm: connectionFormPanel
        case .connectionProgress: connectionProgressPanel
        case .reconnecting: reconnectingPanel
        case .placement: placementPanel
        case .calibrationProgress: calibrationPanel
        case .readyIdle: readyPanel(showActions: false)
        case .readyActive: readyPanel(showActions: true)
        }
    }

    private var cameraPermissionPanel: some View {
        VStack(spacing: 14) {
            titleText(stageTitle)
            character(size: 120)
            bodyText(stageMessage)
            secondaryText("映像はPCへ送信せず、端末内で解析します。")
            filledButton(cameraPermissionPermanentlyDenied ? "設定を開く" : "カメラを許可") {
                cameraPermissionPermanentlyDenied ? onOpenSystemSettings() : onRequestCameraPermission()
            }
        }
    }

    private var cameraErrorPanel: some View {
        VStack(spacing: 14) {
            titleText(stageTitle)
            character(size: 120)
            bodyText(stageMessage)
            filledButton("カメラを再起動", action: onRetryCamera)
        }
    }

    private var connectionFormPanel: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .leading) {
                character(size: 46)
                titleText("PCに接続").frame(maxWidth: .infinity)
            }
            connectionFormFeedback
            connectionField(label: "PCのIPアドレスまたはホスト名入力",
                            text: $host, keyboard: .URL)
            HStack(spacing: 12) {
                connectionField(label: "ポート入力", text: $port, keyboard: .numberPad)
                    .onChange(of: port) { port = String($0.filter(\.isNumber).prefix(5)) }
                connectionField(label: "6桁コード入力", text: $token, keyboard: .numberPad)
                    .onChange(of: token) { token = String($0.filter(\.isNumber).prefix(6)) }
            }
            filledButton("接続", widthFraction: 0.6) {
                formError = onConnect(host, port, token)
            }
        }
    }

    @ViewBuilder
    private var connectionFormFeedback: some View {
        if state.stage == .connectionError {
            feedbackText("\(connectionErrorTitle(state.connection.errorCode))。\(connectionErrorMessage(state.connection.errorCode))")
        } else if let error = formError, !error.isEmpty {
            feedbackText(error)
        } else {
            bodyText("接続情報はPCアプリに\n表示されています！")
        }
    }

    private var connectionProgressPanel: some View {
        VStack(spacing: 12) {
            titleText(stageTitle)
            character(size: 120)
            bodyText(stageMessage)
            secondaryText("接続先  \(host):\(port)")
            outlinedButton("キャンセル", action: onCancelConnection)
            if state.stage == .autoConnecting {
                filledButton("接続先を変更", action: onChangeConnectionSettings)
            }
        }
    }

    private var reconnectingPanel: some View {
        VStack(spacing: 14) {
            titleText(stageTitle)
            bodyText("PCとの接続が途切れました。")
            secondaryText("PCへの座標は送信されていません。\nカメラ解析は継続しています。")
            outlinedButton("今すぐ再接続", action: onRetryNow)
            filledButton("接続設定を変更", action: onChangeConnectionSettings)
            HStack {
                character(size: 105)
                Spacer()
            }
        }
    }

    private var placementPanel: some View {
        VStack(spacing: 16) {
            titleText(stageTitle)
            bodyText("PC画面の4隅がすべて映るように\n端末を固定してください。")
            secondaryText("PC画面全体が映る位置に固定し、\nPCで「配置OK」を\n押してください。")
            HStack { Spacer(); character(size: 112) }
        }
    }

    private var calibrationPanel: some View {
        VStack(spacing: 12) {
            titleText(stageTitle)
            bodyText(stageMessage)
            character(size: 120)
            calibrationProgress
        }
    }

    private func readyPanel(showActions: Bool) -> some View {
        VStack(spacing: 14) {
            titleText(stageTitle)
            character(size: showActions ? 110 : 126)
            bodyText(stageMessage)
            if showActions {
                outlinedButton("PCから切断", action: onDisconnect)
            }
        }
    }

    @ViewBuilder
    private var calibrationProgress: some View {
        switch state.calibration {
        case .placementWaiting:
            secondaryText("PC画面全体が映る位置に固定し、PCで「配置OK」を押してください。")
        case .findingMarkers(let found):
            secondaryText("検出済み \(found)/4")
        case .stabilizing(let current, let required):
            secondaryText("安定度 \(current)/\(required)")
            HStack(spacing: 6) {
                ForEach(0..<min(required, 12), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(index < current ? GuideColors.ink : Color(white: 0.82))
                        .frame(height: 9)
                }
            }
        case .retryRequired(let reason):
            feedbackText(calibrationRetryMessage(reason))
        case .waitingForPc:
            secondaryText("端末を動かさず、そのままお待ちください。")
        case .complete:
            secondaryText("位置合わせが完了しました。")
        case .inactive:
            secondaryText("PCからの位置合わせ開始を待っています。")
        }
    }

    // MARK: - Reusable pieces

    private func titleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .black))
            .foregroundColor(GuideColors.ink)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(GuideColors.bodyInk)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func secondaryText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(GuideColors.bodyInk)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func feedbackText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(GuideColors.error)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func character(size: CGFloat) -> some View {
        Image("production_character")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size * 0.75)
    }

    private func filledButton(_ text: String, widthFraction: CGFloat = 0.84,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 22, weight: .black))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
        }
        .background(GuideColors.button)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity)
        .scaleEffect(x: widthFraction, y: 1, anchor: .center)
    }

    private func outlinedButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 22, weight: .black))
                .foregroundColor(GuideColors.bodyInk)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
        }
        .background(GuideColors.field)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(GuideColors.ink, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity)
    }

    private func connectionField(label: String, text: Binding<String>,
                                 keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(GuideColors.bodyInk)
                .lineLimit(1)
            TextField("", text: text)
                .keyboardType(keyboard)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(GuideColors.ink)
                .padding(.horizontal, 12)
                .frame(height: 52)
                .background(GuideColors.field)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(GuideColors.ink, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(label)
        }
    }

    private var helpButton: some View {
        Button { showHelp = true } label: {
            Text("?")
                .font(.system(size: 22, weight: .black))
                .foregroundColor(GuideColors.ink)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.45))
                .clipShape(Circle())
                .overlay(Circle().stroke(GuideColors.ink, lineWidth: 3))
        }
        .accessibilityLabel("設定・ヘルプ")
    }

    private var helpSheet: some View {
        NavigationView {
            List {
                Section("設置方法") {
                    Text("PC画面全体が映る位置へ端末を固定し、反射や逆光を避けてください。")
                }
                Section("プライバシー") {
                    Text("カメラ映像は端末内で解析され、PCへは手とマーカーの座標だけを送信します。")
                }
                Section {
                    Button("接続先を変更") { showHelp = false; onChangeConnectionSettings() }
                    if state.connection.status == .connected {
                        Button("PCから切断") { showHelp = false; onDisconnect() }
                    }
                    if hasTrustedPc {
                        Button("このPCを忘れる", role: .destructive) { showHelp = false; onForgetTrustedPc() }
                    }
                }
            }
            .navigationTitle("設定・ヘルプ")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showHelp = false }
                }
            }
        }
    }

    // MARK: - Copy (ported verbatim from Android stageTitle/stageMessage/etc.)

    private var stageTitle: String {
        switch state.stage {
        case .cameraPermission: return "手の動きを読み取るためにカメラを使います"
        case .cameraError: return "カメラを起動できません"
        case .connect: return "PCに接続"
        case .connecting: return "PCに接続しています"
        case .autoConnecting: return "前回のPCに接続しています"
        case .connectionError: return connectionErrorTitle(state.connection.errorCode)
        case .reconnecting: return "\(state.connection.retryInSeconds ?? 0)秒後に再接続します"
        case .calibration:
            switch state.calibration {
            case .placementWaiting: return "スマホを固定してください"
            case .findingMarkers: return "4つのマーカーを映してください"
            case .stabilizing: return "そのまま動かさないでください"
            case .waitingForPc, .complete: return "PCで位置を確認しています"
            case .retryRequired: return "位置合わせをやり直します"
            case .inactive: return "PC画面全体をカメラに入れてください"
            }
        case .ready:
            switch state.tracking {
            case .candidate: return "手を確認しています"
            case .tracking: return "手を検出しています"
            case .temporarilyLost: return "手を見失いました"
            case .longLost: return "手が見つかりません"
            default: return "操作できます！"
            }
        }
    }

    private var stageMessage: String {
        switch state.stage {
        case .cameraPermission: return "背面カメラで手とPC画面のマーカーを検出します。"
        case .cameraError: return "ほかのアプリがカメラを使用していないか確認してください。"
        case .connect: return "接続情報はPCアプリに表示されています。"
        case .connecting: return "通常は5秒以内に応答します。"
        case .autoConnecting: return "保存済みの信頼済み接続情報を使用しています。"
        case .connectionError: return connectionErrorMessage(state.connection.errorCode)
        case .reconnecting: return "PCとの接続が切れました。"
        case .calibration: return "PC画面の4隅がすべて映るように端末を固定してください。"
        case .ready:
            switch state.tracking {
            case .temporarilyLost, .longLost: return "カメラの範囲に手を戻し、照明と距離を確認してください。"
            case .tracking: return "PCに接続済みです。"
            default: return "カメラの前に手を映してください。"
            }
        }
    }

    private func connectionErrorTitle(_ code: ConnectionErrorCode?) -> String {
        switch code {
        case .pairingCodeMismatch: return "6桁コードが一致しません"
        case .unsupportedVersion: return "PCアプリを更新してください"
        case .serverBusy: return "PCが処理中です"
        case .ackTimeout: return "PCから応答がありません"
        default: return "PCが見つかりません"
        }
    }

    private func connectionErrorMessage(_ code: ConnectionErrorCode?) -> String {
        switch code {
        case .pairingCodeMismatch: return "PCに表示されたコードを入力し直してください。"
        case .unsupportedVersion: return "iOSアプリと互換性のあるPCアプリが必要です。"
        case .serverBusy: return "しばらく待ってから、もう一度接続してください。"
        case .ackTimeout: return "PCアプリが起動しているか確認してください。"
        default: return "同じネットワーク、IP、ポートを確認してください。"
        }
    }

    private func calibrationRetryMessage(_ reason: CalibrationRetryReason) -> String {
        switch reason {
        case .markersNotVisible: return "4つのマーカーをすべて画面内に入れてください。"
        case .invalidGeometry: return "PC画面を正面から映し、四隅の配置を確認してください。"
        case .unstable: return "端末を固定し、揺れが収まるまで待ってください。"
        case .screenMismatch: return "操作対象のPC画面を映しているか確認してください。"
        case .internalError: return "PC側で処理できませんでした。もう一度お試しください。"
        case .unknown: return "画面全体、照明、端末位置を確認してください。"
        }
    }
}

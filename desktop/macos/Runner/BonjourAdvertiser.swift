import FlutterMacOS
import Foundation

/// Bonjour(mDNS) 広告器。Desktop の WebSocket サーバ（desktop/lib/net/input_server.dart・
/// `ws://<PCのIP>:<port>/ws/v1/input`）を `_screact._tcp` として同一 Wi-Fi へ広告する。
///
/// iOS は生の UDP ブロードキャストを `com.apple.developer.networking.multicast`
/// entitlement 無しに受信できないため、UDP offer 方式（desktop/lib/net/discovery.dart）は
/// iOS の自動接続に使えない。一方 Bonjour ブラウズ/広告は Apple 標準のゼロコンフィグ
/// 経路で、この特別 entitlement 無しに成立する（Info.plist の NSBonjourServices と
/// NSLocalNetworkUsageDescription、macOS 側は network.server entitlement のみで足りる）。
///
/// 6桁ペアリングコードは TXT レコード `token` に載せ、iOS 側（BonjourDiscovery）が
/// 解決時に読み取ってそのまま hello.pairingToken に使う。これによりスマホでの
/// キー入力ゼロで接続が成立する。認証は既存どおり hello の pairingToken 1本のまま
/// （新しい秘密は作らない）。
///
/// Dart からは MethodChannel `yubiboard/bonjour` 経由で publish/stop する。
/// Android 互換の UDP offer は従来どおり並行して流し続ける（本器は iOS 向けの追加経路）。
final class BonjourAdvertiser: NSObject, NetServiceDelegate {
  private static let serviceType = "_screact._tcp."
  private static let domain = "local."

  private let channel: FlutterMethodChannel
  private var service: NetService?
  /// 直近の publish 要求（-72008 等の失敗時にローカルネットワーク許可を待って再試行するため保持）。
  private var pendingPort: Int?
  private var pendingToken: String?
  private var retryCount = 0
  /// 3秒間隔で最大 40 回（約2分）まで再試行。ユーザが「ローカルネットワーク」を許可した後に
  /// アプリを再起動せず自動で広告が立つようにする。
  private static let maxRetries = 40
  private static let retryDelaySeconds: Double = 3

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "yubiboard/bonjour", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(true)
    case "publish":
      guard
        let args = call.arguments as? [String: Any],
        let port = args["port"] as? Int,
        let token = args["token"] as? String,
        port > 0, port <= 65535
      else {
        result(
          FlutterError(code: "bad_args", message: "port(Int)/token(String) が必要です", details: nil))
        return
      }
      retryCount = 0
      publish(port: port, token: token)
      result(true)
    case "stop":
      pendingPort = nil
      pendingToken = nil
      retryCount = 0
      stopService()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func publish(port: Int, token: String) {
    // 再試行のために要求内容を保持する（retryCount はここではリセットしない。
    // start→publish の呼び出しごとにリセットするのは republish 側と区別するため handle で行う）。
    pendingPort = port
    pendingToken = token
    startService(port: port, token: token)
  }

  private func startService(port: Int, token: String) {
    stopService()
    // サービス名は他機と衝突しないホスト名を用いる（Bonjour は同名衝突時に自動採番するが、
    // 分かりやすさのため localizedName を優先）。
    let name = Host.current().localizedName ?? "Screact"
    let newService = NetService(
      domain: Self.domain, type: Self.serviceType, name: name, port: Int32(port))
    var txt: [String: Data] = [:]
    txt["app"] = "screact".data(using: .utf8)
    txt["v"] = "1".data(using: .utf8)
    // iOS が hello.pairingToken にそのまま使う6桁コード。
    txt["token"] = token.data(using: .utf8)
    newService.setTXTRecord(NetService.data(fromTXTRecord: txt))
    newService.delegate = self
    newService.schedule(in: .main, forMode: .common)
    newService.publish()
    service = newService
  }

  private func stopService() {
    guard let service else { return }
    service.stop()
    service.delegate = nil
    self.service = nil
  }

  // MARK: - NetServiceDelegate

  func netServiceDidPublish(_ sender: NetService) {
    retryCount = 0
    channel.invokeMethod(
      "log", arguments: "[Bonjour] 広告開始: \(sender.name) \(sender.type) port=\(sender.port)")
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    let code = errorDict["NSNetServicesErrorCode"]?.intValue ?? 0
    // -72008 (NSNetServicesMissingRequiredConfigurationError) は macOS の
    // 「ローカルネットワーク」許可が未付与のときに即失敗する。許可後に自動復帰させるため再試行する。
    if retryCount < Self.maxRetries, let port = pendingPort, let token = pendingToken {
      retryCount += 1
      if retryCount == 1 {
        channel.invokeMethod(
          "log",
          arguments:
            "[Bonjour] 広告失敗(code=\(code))。macOSの「システム設定 > プライバシーとセキュリティ > "
            + "ローカルネットワーク」でこのアプリを許可してください。許可後は自動で再試行します。")
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelaySeconds) { [weak self] in
        guard let self, self.pendingPort == port, self.pendingToken == token else { return }
        self.startService(port: port, token: token)
      }
    } else {
      channel.invokeMethod(
        "log", arguments: "[Bonjour] 広告失敗(code=\(code))。再試行上限に達しました。")
    }
  }
}

import Foundation

/// Bonjour(mDNS) による PC の自動発見。Desktop が `_screact._tcp` として広告する
/// WebSocket サーバ（desktop/macos/Runner/BonjourAdvertiser.swift）をブラウズ・解決し、
/// host/port と TXT レコードの6桁トークンを取り出して `ConnectionConfig` を組み立てる。
///
/// なぜ Bonjour か: iOS は生の UDP ブロードキャストを
/// `com.apple.developer.networking.multicast` entitlement 無しに受信できないため、
/// Desktop の UDP offer 方式（desktop/lib/net/discovery.dart）では iOS の自動接続が
/// 原理的に成立しない。一方、Bonjour ブラウズは Apple 標準のゼロコンフィグ経路で、
/// この特別 entitlement 無しに成立する。必要なのは Info.plist の NSBonjourServices
/// （`_screact._tcp`）と NSLocalNetworkUsageDescription・NSAllowsLocalNetworking のみ。
///
/// 発見時に host/port/token が揃うため、ユーザは6桁コードを入力せずに接続できる
/// （キー入力ゼロ）。認証は既存どおり hello.pairingToken 1本のまま（TXT はその配達手段）。
/// 手入力フォームはフォールバックとして従来どおり残る。
///
/// スレッド: NetServiceBrowser / NetService はメインの RunLoop に載せて駆動する。
/// 呼び出し・コールバックはすべてメインスレッドで行うこと（MainViewModel は @MainActor）。
final class BonjourDiscovery: NSObject {
  static let serviceType = "_screact._tcp."
  static let domain = "local."

  /// 解決成功時に host/port/token の揃った接続先を通知する。メインスレッドで呼ばれる。
  private let onDiscovered: (ConnectionConfig) -> Void
  private let onLog: (String) -> Void

  private var browser: NetServiceBrowser?
  /// 解決中の NetService を強参照で保持する（解放されると解決が中断されるため）。
  private var resolving: [NetService] = []
  private var isRunning = false
  /// 再検索ループの世代。stop() で更新して予約済みリトライを無効化する。
  private var searchGeneration = 0
  /// Android の UDP 常時待受と同様、接続成立（stop 呼び出し）までブラウズを粘り強く再試行する間隔。
  /// 初回の「ローカルネットワーク」許可でブラウズが落ちても、許可後に自動復帰させるのが狙い。
  private static let retryInterval: TimeInterval = 3

  init(
    onDiscovered: @escaping (ConnectionConfig) -> Void,
    onLog: @escaping (String) -> Void = { _ in }
  ) {
    self.onDiscovered = onDiscovered
    self.onLog = onLog
    super.init()
  }

  /// ブラウズを開始する。多重開始は無視する。
  func start() {
    guard !isRunning else { return }
    isRunning = true
    searchGeneration &+= 1
    beginSearch()
    scheduleRetry(generation: searchGeneration)
    onLog("[Bonjour] PC を検索開始: \(Self.serviceType)")
  }

  /// NetServiceBrowser を作り直してブラウズを張り直す。
  private func beginSearch() {
    browser?.stop()
    browser?.delegate = nil
    let newBrowser = NetServiceBrowser()
    // 同一 Wi-Fi に加え AWDL(ピアツーピア)経由でも検出できるようにする。
    newBrowser.includesPeerToPeer = true
    newBrowser.delegate = self
    newBrowser.schedule(in: .main, forMode: .common)
    newBrowser.searchForServices(ofType: Self.serviceType, inDomain: Self.domain)
    browser = newBrowser
  }

  /// 接続成立（stop）まで未発見なら再検索を続ける。Android の常時待受と挙動を揃える。
  /// 解決中（resolve 進行中）は割り込まない。
  private func scheduleRetry(generation: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
      guard let self, self.isRunning, generation == self.searchGeneration else { return }
      if self.resolving.isEmpty {
        self.beginSearch()
        self.onLog("[Bonjour] 未発見のため再検索します")
      }
      self.scheduleRetry(generation: generation)
    }
  }

  /// ブラウズと解決を停止し、保持を解放する。
  func stop() {
    guard isRunning else { return }
    isRunning = false
    searchGeneration &+= 1   // 予約済みの再検索リトライを無効化する
    browser?.stop()
    browser?.delegate = nil
    browser = nil
    for service in resolving {
      service.stop()
      service.delegate = nil
    }
    resolving.removeAll()
  }

  private func beginResolve(_ service: NetService) {
    service.delegate = self
    service.schedule(in: .main, forMode: .common)
    resolving.append(service)
    // 5秒でタイムアウト。解決できなければ didNotResolve で破棄する。
    service.resolve(withTimeout: 5)
  }

  private func drop(_ service: NetService) {
    service.stop()
    service.delegate = nil
    resolving.removeAll { $0 === service }
  }

  /// sockaddr の配列から最初の IPv4 アドレス文字列を取り出す。
  /// 数値 IP を優先して使うと、`.local` 名前解決に依存せず最も確実に接続できる。
  private static func firstIPv4(from addresses: [Data]?) -> String? {
    guard let addresses else { return nil }
    for data in addresses {
      let host: String? = data.withUnsafeBytes { raw -> String? in
        guard let base = raw.baseAddress else { return nil }
        let sa = base.assumingMemoryBound(to: sockaddr.self)
        guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
          var addr = sin.pointee.sin_addr
          guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
          }
          return String(cString: buffer)
        }
        return result
      }
      if let host { return host }
    }
    return nil
  }
}

// MARK: - NetServiceBrowserDelegate

extension BonjourDiscovery: NetServiceBrowserDelegate {
  func netServiceBrowser(
    _ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool
  ) {
    beginResolve(service)
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool
  ) {
    drop(service)
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]
  ) {
    onLog("[Bonjour] 検索に失敗: \(errorDict)")
  }
}

// MARK: - NetServiceDelegate

extension BonjourDiscovery: NetServiceDelegate {
  func netServiceDidResolveAddress(_ sender: NetService) {
    defer { drop(sender) }

    // TXT レコードから6桁トークンを取り出す。
    var token: String?
    if let txtData = sender.txtRecordData() {
      let dict = NetService.dictionary(fromTXTRecord: txtData)
      if let raw = dict["token"], let value = String(data: raw, encoding: .utf8) {
        token = value
      }
    }
    guard let token, token.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else {
      onLog("[Bonjour] \(sender.name) を解決したが有効なトークンが無いため無視")
      return
    }

    // 数値 IPv4 を優先。無ければ hostName（末尾の "." を除去）でフォールバック。
    let host: String? =
      Self.firstIPv4(from: sender.addresses)
      ?? sender.hostName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
    guard let host, !host.isEmpty, (1...65535).contains(sender.port) else {
      onLog("[Bonjour] \(sender.name) の host/port を取得できず無視")
      return
    }

    let config = ConnectionConfig(host: host, port: sender.port, pairingToken: token)
    if let error = config.validate() {
      onLog("[Bonjour] 発見した接続先が不正: \(error)")
      return
    }
    onLog("[Bonjour] PC 発見: \(host):\(sender.port) — 自動接続します")
    onDiscovered(config)
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    onLog("[Bonjour] \(sender.name) の解決に失敗: \(errorDict)")
    drop(sender)
  }
}

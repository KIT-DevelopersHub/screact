import Foundation

/// Port of Android ConnectionModels. Builds the exact desktop endpoint
/// `ws://<host>:<port>/ws/v1/input` (see desktop/lib/net/input_server.dart).
struct ConnectionConfig {
    let host: String
    let port: Int
    var pairingToken: String?
    var resumeToken: String?

    var webSocketUrl: String { "ws://\(host):\(port)/ws/v1/input" }

    func validate() -> String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            return "PCのIPアドレスを入力してください"
        }
        if !(1...65535).contains(port) {
            return "ポートは1〜65535で入力してください"
        }
        if (pairingToken != nil) == (resumeToken != nil) {
            return "ペアリングコードと再接続情報のどちらか一方が必要です"
        }
        if let token = pairingToken, token.range(of: "^[0-9]{6}$", options: .regularExpression) == nil {
            return "ペアリングコードは6桁の数字です"
        }
        if let resume = resumeToken, resume.isEmpty {
            return "保存済みの再接続情報が不正です"
        }
        return nil
    }
}

enum ConnectionStatus {
    case disconnected
    case connecting
    case awaitingAck
    case connected
    case reconnecting
    case error
}

enum ConnectionErrorCode {
    case pairingCodeMismatch
    case unsupportedVersion
    case serverBusy
    case unreachable
    case ackTimeout
    case resumeTokenInvalid
    case unknown
}

struct ConnectionSnapshot {
    var status: ConnectionStatus
    var sessionId: String?
    var retryInSeconds: Int?
    var detail: String?
    var errorCode: ConnectionErrorCode?
    var automatic: Bool

    init(_ status: ConnectionStatus,
         sessionId: String? = nil,
         retryInSeconds: Int? = nil,
         detail: String? = nil,
         errorCode: ConnectionErrorCode? = nil,
         automatic: Bool = false) {
        self.status = status
        self.sessionId = sessionId
        self.retryInSeconds = retryInSeconds
        self.detail = detail
        self.errorCode = errorCode
        self.automatic = automatic
    }
}

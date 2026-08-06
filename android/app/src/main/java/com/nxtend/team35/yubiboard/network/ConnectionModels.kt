package com.nxtend.team35.yubiboard.network

data class ConnectionConfig(
    val host: String,
    val port: Int,
    val pairingToken: String? = null,
    val resumeToken: String? = null,
) {
    val webSocketUrl: String get() = "ws://$host:$port/ws/v1/input"

    fun validate(): String? = when {
        host.isBlank() -> "PCのIPアドレスを入力してください"
        port !in 1..65535 -> "ポートは1〜65535で入力してください"
        (pairingToken != null) == (resumeToken != null) ->
            "ペアリングコードと再接続情報のどちらか一方が必要です"
        pairingToken != null && !pairingToken.matches(Regex("^[0-9]{6}$")) ->
            "ペアリングコードは6桁の数字です"
        resumeToken != null && resumeToken.isBlank() -> "保存済みの再接続情報が不正です"
        else -> null
    }
}

enum class ConnectionStatus {
    DISCONNECTED,
    CONNECTING,
    AWAITING_ACK,
    CONNECTED,
    RECONNECTING,
    ERROR,
}

enum class ConnectionErrorCode {
    PAIRING_CODE_MISMATCH,
    UNSUPPORTED_VERSION,
    SERVER_BUSY,
    UNREACHABLE,
    ACK_TIMEOUT,
    RESUME_TOKEN_INVALID,
    UNKNOWN,
}

data class ConnectionSnapshot(
    val status: ConnectionStatus,
    val sessionId: String? = null,
    val retryInSeconds: Int? = null,
    val detail: String? = null,
    val errorCode: ConnectionErrorCode? = null,
    val automatic: Boolean = false,
)

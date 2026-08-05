package com.nxtend.team35.yubiboard.network

data class ConnectionConfig(
    val host: String,
    val port: Int,
    val pairingToken: String,
) {
    val webSocketUrl: String get() = "ws://$host:$port/ws/v1/input"

    fun validate(): String? = when {
        host.isBlank() -> "PCのIPアドレスを入力してください"
        port !in 1..65535 -> "ポートは1〜65535で入力してください"
        !pairingToken.matches(Regex("^[0-9]{6}$")) -> "ペアリングコードは6桁の数字です"
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

data class ConnectionSnapshot(
    val status: ConnectionStatus,
    val sessionId: String? = null,
    val retryInSeconds: Int? = null,
    val detail: String? = null,
)

package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import kotlin.concurrent.thread

/**
 * 「画面認識開始」押下後の待受け。UDP :8766 で Desktop の discovery_offer を
 * 待ち、応答(discovery_response)を送信元へユニキャスト返信する。Desktop に
 * 選ばれる（discovery_select 受信）と onSelected(host, wsPort, token) を1回
 * 呼んで待受を終了する。host は select の送信元アドレスを優先する
 * （offer の ip フィールドは参考値）。
 *
 * WifiManager.MulticastLock はブロードキャスト受信をフィルタする端末向け。
 * 呼び出し側（ViewModel）が acquire/release 可能な形で渡す（テストでは null）。
 */
class DesktopDiscoveryListener(
    private val deviceId: String,
    private val deviceName: String,
    private val model: String,
    private val onSelected: (host: String, wsPort: Int, token: String) -> Unit,
    private val onLog: (String) -> Unit = {},
    private val port: Int = DISCOVERY_PORT,
    private val multicastLock: Lock? = null,
) {
    /** WifiManager.MulticastLock の抽象（テスト差し替え用）。 */
    interface Lock {
        fun acquire()
        fun release()
    }

    @Volatile
    private var socket: DatagramSocket? = null

    @Volatile
    private var running = false
    private var worker: Thread? = null

    /** 実際に待受けているポート（port=0 指定時のテスト用）。未起動なら null。 */
    val boundPort: Int? get() = socket?.localPort?.takeIf { it > 0 }

    val isRunning: Boolean get() = running

    @Synchronized
    fun start() {
        if (running) return
        // 注意: apply 内の `port` は DatagramSocket.port(-1) を指すため
        // 必ず外側のリッスンポートを明示する。
        val listenPort = port
        val bound = DatagramSocket(null).apply {
            reuseAddress = true
            broadcast = true
            bind(InetSocketAddress(listenPort))
        }
        socket = bound
        running = true
        runCatching { multicastLock?.acquire() }
        AppDiagnostics.event("discovery", "listen_started", mapOf("port" to bound.localPort))
        onLog("PCの検出待ち: UDP ${bound.localPort} で待受中")
        worker = thread(name = "screact-discovery", isDaemon = true) { loop(bound) }
    }

    private fun loop(socket: DatagramSocket) {
        val buffer = ByteArray(RECEIVE_BUFFER_BYTES)
        var respondedOnce = false
        while (running) {
            val packet = DatagramPacket(buffer, buffer.size)
            try {
                socket.receive(packet)
            } catch (_: Exception) {
                if (running) onLog("検出待ちの受信に失敗しました")
                return
            }
            val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
            when (val message = DiscoveryCodec.parse(text)) {
                is DiscoveryOffer -> {
                    if (!respondedOnce) {
                        respondedOnce = true
                        AppDiagnostics.event(
                            "discovery",
                            "offer_received",
                            mapOf("from" to packet.address?.hostAddress, "wsPort" to message.wsPort),
                        )
                        onLog("PCを検出しました。選択を待っています…")
                    }
                    val reply = DiscoveryCodec.encode(
                        DiscoveryResponse(deviceId = deviceId, deviceName = deviceName, model = model),
                    ).toByteArray(Charsets.UTF_8)
                    runCatching {
                        socket.send(DatagramPacket(reply, reply.size, packet.address, packet.port))
                    }.onFailure {
                        AppDiagnostics.event("discovery", "response_send_failed", mapOf("message" to it.message))
                    }
                }

                is DiscoverySelect -> {
                    if (message.deviceId != deviceId || !message.selected) continue
                    val host = packet.address?.hostAddress ?: message.ip ?: continue
                    AppDiagnostics.event(
                        "discovery",
                        "selected",
                        mapOf("host" to host, "wsPort" to message.wsPort),
                    )
                    onLog("PCに選択されました。自動接続します")
                    stop()
                    onSelected(host, message.wsPort, message.token)
                    return
                }

                is DiscoveryResponse, null -> Unit // 他端末の応答・無関係なデータは無視
            }
        }
    }

    @Synchronized
    fun stop() {
        if (!running && socket == null) return
        running = false
        runCatching { multicastLock?.release() }
        socket?.close()
        socket = null
        worker = null
        AppDiagnostics.event("discovery", "listen_stopped")
    }

    companion object {
        private const val RECEIVE_BUFFER_BYTES = 4096
    }
}

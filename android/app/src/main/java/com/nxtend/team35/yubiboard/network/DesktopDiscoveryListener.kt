package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import kotlin.concurrent.thread

/**
 * 「画面認識開始」押下後の待受け。UDP :8766 で Desktop の discovery_offer を
 * 待ち、offer を受けた時点で **自分から** PC の WebSocket へ接続しに行く
 * （onConnect(host, wsPort, token) を1回呼ぶ）。host は offer の送信元
 * アドレスを優先する（offer の ip フィールドは参考値）。
 *
 * 【接続の向きを反転した理由（TCC非依存化）】
 * 実機で、PC(macOS)の「ローカルネットワーク」権限が未許可だと PC からの
 * アウトバウンドUDP（discovery_select のユニキャスト/ブロードキャスト）が
 * OSに落とされ、Android に届かないことを確認した（offer は届き response も
 * 返るのに select だけ届かない非対称）。そこで PC→Android の生UDPユニ
 * キャスト(select)を接続確立の必須経路から外し、offer に含まれる
 * ip/wsPort/token を使って Android 側から WS を張る。Android→PC の
 * アウトバウンド（response・WS hello）は生きているため権限に依存しない。
 *
 * response(discovery_response) は PC のUI/ログ表示用に最初の offer に対して
 * 1回返す（接続自体は response に依存しない）。discovery_select を受けた
 * 場合は後方互換で ACK を返すが、接続トリガにはしない。
 *
 * WifiManager.MulticastLock はブロードキャスト受信をフィルタする端末向け。
 * 呼び出し側（ViewModel）が acquire/release 可能な形で渡す（テストでは null）。
 */
class DesktopDiscoveryListener(
    private val deviceId: String,
    private val deviceName: String,
    private val model: String,
    private val onConnect: (host: String, wsPort: Int, token: String) -> Unit,
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
        var connectedOnce = false
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
                    if (connectedOnce) continue // 接続開始済み: 以後の offer は無視
                    // offer の送信元アドレスを最優先（NATや複数IFでも確実）。
                    val host = packet.address?.hostAddress ?: message.ip ?: continue
                    AppDiagnostics.event(
                        "discovery",
                        "offer_received",
                        mapOf("from" to host, "wsPort" to message.wsPort),
                    )
                    onLog("PCを検出しました。自動で接続します…")
                    // PC のUI/ログ表示用に response を1回返す（接続には不要）。
                    val reply = DiscoveryCodec.encode(
                        DiscoveryResponse(deviceId = deviceId, deviceName = deviceName, model = model),
                    ).toByteArray(Charsets.UTF_8)
                    runCatching {
                        socket.send(DatagramPacket(reply, reply.size, packet.address, packet.port))
                    }.onFailure {
                        AppDiagnostics.event("discovery", "response_send_failed", mapOf("message" to it.message))
                    }
                    // 接続の向きを反転: Android から PC の WS へ張りに行く。
                    connectedOnce = true
                    AppDiagnostics.event(
                        "discovery",
                        "connect_from_offer",
                        mapOf("host" to host, "wsPort" to message.wsPort),
                    )
                    onConnect(host, message.wsPort, message.token)
                }

                is DiscoverySelect -> {
                    // 後方互換: PC が select を送ってきたら ACK を返す（接続トリガ
                    // にはしない。接続は offer 受信で既に開始している）。
                    if (message.deviceId != deviceId || !message.selected) continue
                    val ack = DiscoveryCodec.encode(DiscoverySelectAck(deviceId = deviceId))
                        .toByteArray(Charsets.UTF_8)
                    runCatching {
                        socket.send(DatagramPacket(ack, ack.size, packet.address, packet.port))
                        AppDiagnostics.event(
                            "discovery",
                            "select_ack_sent",
                            mapOf("to" to packet.address?.hostAddress),
                        )
                    }.onFailure {
                        AppDiagnostics.event("discovery", "select_ack_send_failed", mapOf("message" to it.message))
                    }
                }

                is DiscoveryResponse, is DiscoverySelectAck, null -> Unit // 他端末の応答等は無視
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

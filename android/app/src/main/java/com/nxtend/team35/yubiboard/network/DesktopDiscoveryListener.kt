package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress

/**
 * 「画面認識開始」押下後の待受け。UDP :8766 で Desktop の discovery_offer を
 * 待ち、offer を受けた時点で **自分から** PC の WebSocket へ接続しに行く
 * （onConnect(host, wsPort, token) を1回呼ぶ）。host は offer の送信元
 * アドレスを優先する（offer の ip フィールドは参考値）。
 *
 * 【現行経路とローカルネットワーク権限】
 * PC→Android の discovery_select ユニキャストは接続確立の必須経路から外した。
 * ただし、最初の discovery_offer は PC から LAN への UDP broadcast である。
 * そのため自動発見は macOS のローカルネットワーク許可、OSファイアウォール、
 * AP isolation などの到達性に依存する。offer broadcast 自体が抑止される環境では
 * 自動発見は成立せず、UI から手動接続へフォールバックする。
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
    private val socketFactory: () -> DatagramSocket = { DatagramSocket(null) },
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
    private var multicastLockHeld = false

    /** 実際に待受けているポート（port=0 指定時のテスト用）。未起動なら null。 */
    val boundPort: Int? get() = socket?.localPort?.takeIf { it > 0 }

    val isRunning: Boolean get() = running

    @Synchronized
    fun start() {
        if (running) return
        // 注意: apply 内の `port` は DatagramSocket.port(-1) を指すため
        // 必ず外側のリッスンポートを明示する。
        val listenPort = port
        val bound = socketFactory()
        try {
            bound.reuseAddress = true
            bound.broadcast = true
            bound.bind(InetSocketAddress(listenPort))
        } catch (error: Throwable) {
            bound.close()
            throw error
        }
        socket = bound
        running = true
        try {
            multicastLock?.acquire()
            multicastLockHeld = multicastLock != null
            AppDiagnostics.event("discovery", "listen_started", mapOf("port" to bound.localPort))
            onLog("PCの検出待ち: UDP ${bound.localPort} で待受中")
            val nextWorker = Thread({ loop(bound) }, "screact-discovery").apply {
                isDaemon = true
            }
            worker = nextWorker
            nextWorker.start()
        } catch (error: Throwable) {
            socket = null
            bound.close()
            releaseMulticastLock()
            worker = null
            running = false
            throw error
        }
    }

    private fun loop(bound: DatagramSocket) {
        val buffer = ByteArray(RECEIVE_BUFFER_BYTES)
        var connectedOnce = false
        try {
            while (running && socket === bound) {
                val packet = DatagramPacket(buffer, buffer.size)
                bound.receive(packet)
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
                            bound.send(DatagramPacket(reply, reply.size, packet.address, packet.port))
                        }.onFailure {
                            AppDiagnostics.event(
                                "discovery",
                                "response_send_failed",
                                mapOf("message" to it.message),
                            )
                        }
                        // 現行フローの正本: Android から PC の WS へ張りに行く。
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
                            bound.send(DatagramPacket(ack, ack.size, packet.address, packet.port))
                            AppDiagnostics.event(
                                "discovery",
                                "select_ack_sent",
                                mapOf("to" to packet.address?.hostAddress),
                            )
                        }.onFailure {
                            AppDiagnostics.event(
                                "discovery",
                                "select_ack_send_failed",
                                mapOf("message" to it.message),
                            )
                        }
                    }

                    is DiscoveryResponse, is DiscoverySelectAck, null -> Unit // 他端末の応答等は無視
                }
            }
        } catch (error: Exception) {
            if (running && socket === bound) {
                onLog("検出待ちの受信に失敗しました")
                AppDiagnostics.event(
                    "discovery",
                    "receive_failed",
                    mapOf("message" to error.message),
                )
            }
        } finally {
            finishWorker(bound)
        }
    }

    @Synchronized
    fun stop() {
        val bound = socket
        if (!running && bound == null) return
        socket = null
        bound?.close()
        releaseMulticastLock()
        worker = null
        running = false
        AppDiagnostics.event("discovery", "listen_stopped")
    }

    @Synchronized
    private fun finishWorker(bound: DatagramSocket) {
        if (socket !== bound) return
        socket = null
        bound.close()
        releaseMulticastLock()
        worker = null
        running = false
        AppDiagnostics.event("discovery", "listen_stopped")
    }

    private fun releaseMulticastLock() {
        if (!multicastLockHeld) return
        multicastLockHeld = false
        runCatching { multicastLock?.release() }
    }

    companion object {
        private const val RECEIVE_BUFFER_BYTES = 4096
    }
}

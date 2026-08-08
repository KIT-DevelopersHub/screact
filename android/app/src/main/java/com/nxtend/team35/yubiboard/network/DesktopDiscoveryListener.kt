package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import kotlin.concurrent.thread

/**
 * 「画面認識開始」押下後の待受け。UDP :8766 で Desktop の discovery_offer を
 * 待ち、応答(discovery_response)を送信元へユニキャスト返信する。Desktop に
 * 選ばれる（discovery_select 受信）と ACK(discovery_select_ack) を返信した
 * うえで onSelected(host, wsPort, token) を1回呼ぶ。host は select の送信元
 * アドレスを優先する（offer の ip フィールドは参考値）。
 *
 * select 受信後も待受は止めない: Desktop は ACK を受信するまで select を
 * 再送するため、重複 select に ACK を返し続ける必要がある（最初の ACK が
 * 落ちた場合の到達保証）。待受の終了は呼び出し側（ViewModel）が WebSocket
 * 確立後などに stop() で行う。
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
        var selectedOnce = false
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
                    if (selectedOnce) continue // 選択済み: 以後の offer には応答しない
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
                    // 到達保証: select を受けるたび（再送された重複分にも）ACK を
                    // ユニキャスト返信する。Desktop は ACK 受信まで select を再送する。
                    val ack = DiscoveryCodec.encode(DiscoverySelectAck(deviceId = deviceId))
                        .toByteArray(Charsets.UTF_8)
                    runCatching {
                        socket.send(DatagramPacket(ack, ack.size, packet.address, packet.port))
                        AppDiagnostics.event(
                            "discovery",
                            "select_ack_sent",
                            mapOf("to" to packet.address?.hostAddress, "duplicate" to selectedOnce),
                        )
                    }.onFailure {
                        AppDiagnostics.event("discovery", "select_ack_send_failed", mapOf("message" to it.message))
                    }
                    if (selectedOnce) continue // 自動接続の開始は最初の1回だけ
                    selectedOnce = true
                    AppDiagnostics.event(
                        "discovery",
                        "selected",
                        mapOf("host" to host, "wsPort" to message.wsPort),
                    )
                    onLog("PCに選択されました。自動接続します")
                    // 待受はここでは止めない（重複 select への ACK 返信を続ける）。
                    // 終了は ViewModel が WebSocket 確立/切断時に stop() する。
                    onSelected(host, message.wsPort, message.token)
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

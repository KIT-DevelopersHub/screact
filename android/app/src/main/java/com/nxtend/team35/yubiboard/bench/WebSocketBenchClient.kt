package com.nxtend.team35.yubiboard.bench

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * BLE と比べるための WebSocket 経路（計測専用）。PC の bench.py が待ち受けるサーバへ接続する。
 * バイナリはバイナリフレーム、JSON は本番と同じ文字列フレームで送る。
 */
class WebSocketBenchClient(
    private val url: String,
    private val log: (String) -> Unit,
) : BenchTransport {
    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    private val reconnect = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var socket: WebSocket? = null
    @Volatile private var closed = false
    val engine = BenchEngine(this, log = log)

    @Volatile var status: String = "idle"
        private set

    fun start() {
        engine.start()
        connect()
    }

    fun stop() {
        closed = true
        engine.shutdown()
        socket?.close(1000, "bench finished")
        reconnect.shutdownNow()
        client.dispatcher.executorService.shutdown()
        status = "stopped"
    }

    override fun maxUnitBytes(): Int = Int.MAX_VALUE

    override fun sendFrameUnit(bytes: ByteArray): Boolean {
        val ws = socket ?: return false
        // JSON（先頭が '{'）は本番と同じ文字列フレームにする。
        return if (bytes.isNotEmpty() && bytes[0] == '{'.code.toByte()) {
            ws.send(String(bytes, Charsets.UTF_8))
        } else {
            ws.send(bytes.toByteString())
        }
    }

    override fun sendControl(bytes: ByteArray): Boolean = socket?.send(bytes.toByteString()) ?: false

    private fun connect() {
        if (closed) return
        status = "connecting $url"
        client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                socket = webSocket
                status = "connected"
                log("ws connected")
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                engine.onControl(bytes.toByteArray())
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = retry("closed $code")

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                retry("failure ${t.javaClass.simpleName}")

            private fun retry(reason: String) {
                socket = null
                status = "disconnected: $reason"
                if (!closed) runCatching { reconnect.schedule({ connect() }, 1, TimeUnit.SECONDS) }
            }
        })
    }
}

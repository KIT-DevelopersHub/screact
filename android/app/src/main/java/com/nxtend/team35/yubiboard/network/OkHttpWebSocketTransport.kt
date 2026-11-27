package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** OkHttp の WebSocket を [InputTransport] として使う薄い層。 */
class OkHttpWebSocketTransport(
    private val httpClient: OkHttpClient,
) : InputTransport {

    override fun open(config: ConnectionConfig, listener: InputTransportListener): TransportConnection {
        val connection = Connection()
        val request = Request.Builder().url(config.webSocketUrl).build()
        connection.socket = httpClient.newWebSocket(request, Listener(connection, listener))
        return connection
    }

    override fun shutdown() {
        httpClient.dispatcher.executorService.shutdown()
        httpClient.connectionPool.evictAll()
    }

    private class Connection : TransportConnection {
        // newWebSocket の戻り値を代入する前に listener が呼ばれても送れるよう、
        // listener 側でも同じ WebSocket を代入する。
        @Volatile
        lateinit var socket: WebSocket

        override val kind: String = "websocket"

        override fun send(text: String): Boolean = socket.send(text)

        override fun queuedBytes(): Long = socket.queueSize()

        override fun close(code: Int, reason: String) {
            socket.close(code, reason)
        }

        override fun cancel() {
            socket.cancel()
        }
    }

    private class Listener(
        private val connection: Connection,
        private val listener: InputTransportListener,
    ) : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            connection.socket = webSocket
            listener.onOpened(connection, mapOf("responseCode" to response.code))
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            listener.onText(connection, text)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            listener.onClosed(connection, "接続が閉じられました: $code $reason")
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            AppDiagnostics.event(
                "network",
                "websocket_failure",
                mapOf(
                    "exception" to t.javaClass.simpleName,
                    "responseCode" to response?.code,
                ),
            )
            listener.onClosed(connection, t.message ?: "通信エラー")
        }
    }
}

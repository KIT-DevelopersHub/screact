package com.nxtend.team35.yubiboard.network

/**
 * Desktop への通信路（transport）の抽象。
 *
 * セッション処理（hello/hello_ack、heartbeat、最新フレーム優先の送信、位置合わせの送信、
 * 再接続、[ConnectionSnapshot] の更新）は [InputSession] が持ち、通信路は接続の確立、
 * テキストメッセージの送受信、切断通知だけを受け持つ。WebSocket 以外の経路（BLE など）を
 * 足すときも、ここを実装すればセッション処理を二重実装せずに済む。
 * Desktop 側の `desktop/lib/net/input_transport.dart` と同じ分け方。
 */
interface InputTransport {
    /**
     * [config] の相手へ接続を始める。確立や切断は [listener] へ通知する。
     * 戻り値の接続は、確立前でも送信・切断の対象として扱える。
     */
    fun open(config: ConnectionConfig, listener: InputTransportListener): TransportConnection

    /** 通信路が持つ資源（スレッド・接続プール）を解放する。以後 [open] は呼ばない。 */
    fun shutdown()
}

/** 1 本の接続。メッセージ単位で送れて、閉じられるもの。 */
interface TransportConnection {
    /** 接続診断ログのイベント名に使う経路名（例: `websocket`）。 */
    val kind: String

    /** テキストメッセージ（protocol v1 の JSON）を 1 件送る。送信キューへ積めなければ false。 */
    fun send(text: String): Boolean

    /** 送信待ちのバイト数。送信の間引きに使う。 */
    fun queuedBytes(): Long

    /** 相手へ理由を伝えて閉じる。 */
    fun close(code: Int, reason: String)

    /** 送信待ちを捨てて直ちに切る。切断は [InputTransportListener.onClosed] で通知される。 */
    fun cancel()
}

/**
 * 通信路から届く接続の出来事を受け取る側。
 *
 * 1 本の接続について次の順で呼ばれる:
 * [onOpened] → 0 回以上の [onText] → [onClosed]（多くても 1 回）。
 * 呼び出し元のスレッドは通信路ごとに異なる。受け手は接続の同一性で古い接続の通知を無視する。
 */
interface InputTransportListener {
    /** 接続が確立した。[details] は接続診断ログ用の補足（応答コードなど）。 */
    fun onOpened(connection: TransportConnection, details: Map<String, Any?> = emptyMap())

    /** テキストメッセージを 1 件受信した。 */
    fun onText(connection: TransportConnection, text: String)

    /** 接続が切れた（相手からの切断・通信エラー・こちらからの切断の完了）。 */
    fun onClosed(connection: TransportConnection, detail: String)
}

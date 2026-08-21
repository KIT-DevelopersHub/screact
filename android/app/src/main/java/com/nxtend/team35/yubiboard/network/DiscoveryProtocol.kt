package com.nxtend.team35.yubiboard.network

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.InetAddress

/**
 * Screact ゼロコンフィグ・ペアリングの UDP 発見プロトコル。
 * Desktop が discovery_offer をブロードキャストし、Android も discovery_probe を
 * ブロードキャストする。待受中の Android は届いたofferの wsPort/token を使って
 * WebSocket (/ws/v1/input) へ自動接続する。
 * discovery_response は Desktop の表示・ログ用、discovery_select/ack は旧フローとの
 * 後方互換用であり、現行の接続成立には必要としない。
 */
const val DISCOVERY_APP = "screact"
const val DISCOVERY_PORT = 8766
const val DISCOVERY_SCHEMA_VERSION = 1
const val DISCOVERY_DEVICE_ID_MAX_LENGTH = 128

sealed interface DiscoveryMessage

/** Android→broadcast: Desktop の offer をユニキャストで要求する探索通知。 */
@Serializable
data class DiscoveryProbe(
    val app: String = DISCOVERY_APP,
    val schemaVersion: Int = DISCOVERY_SCHEMA_VERSION,
    val messageType: String = "discovery_probe",
    val deviceId: String,
) : DiscoveryMessage

/** Desktop→broadcast: 接続情報の広告。 */
@Serializable
data class DiscoveryOffer(
    val app: String = DISCOVERY_APP,
    val schemaVersion: Int = DISCOVERY_SCHEMA_VERSION,
    val messageType: String = "discovery_offer",
    val ip: String? = null,
    val wsPort: Int,
    val token: String,
) : DiscoveryMessage

/** Android→Desktop(ユニキャスト): 「ここにいます」。 */
@Serializable
data class DiscoveryResponse(
    val app: String = DISCOVERY_APP,
    val schemaVersion: Int = DISCOVERY_SCHEMA_VERSION,
    val messageType: String = "discovery_response",
    val deviceId: String,
    val deviceName: String,
    val model: String,
) : DiscoveryMessage

/** Desktop→選択した端末(ユニキャスト): 接続許可。 */
@Serializable
data class DiscoverySelect(
    val app: String = DISCOVERY_APP,
    val schemaVersion: Int = DISCOVERY_SCHEMA_VERSION,
    val messageType: String = "discovery_select",
    val deviceId: String,
    val selected: Boolean = true,
    val ip: String? = null,
    val wsPort: Int,
    val token: String,
) : DiscoveryMessage

/**
 * Android→Desktop(ユニキャスト): select の受領確認。UDP の select は落ちる
 * ことがあるため、Desktop は ACK を受信するまで select を再送する。
 * Android は select を受信するたび（重複分にも）ACK を返す。
 */
@Serializable
data class DiscoverySelectAck(
    val app: String = DISCOVERY_APP,
    val schemaVersion: Int = DISCOVERY_SCHEMA_VERSION,
    val messageType: String = "discovery_select_ack",
    val deviceId: String,
) : DiscoveryMessage

object DiscoveryCodec {
    // encodeDefaults: app/messageType 等のデフォルト値フィールドも必ず出力する
    // （デスクトップ側は app=="screact" を必須マーカーとして照合する）。
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    /** Screact の発見メッセージだけを解釈する（他アプリ/壊れたJSONは null）。 */
    fun parse(text: String): DiscoveryMessage? {
        val element = runCatching { json.parseToJsonElement(text) }.getOrNull() ?: return null
        val obj = runCatching { element.jsonObject }.getOrNull() ?: return null
        if (obj["app"]?.jsonPrimitive?.contentOrNullSafe() != DISCOVERY_APP) return null
        val message = when (obj["messageType"]?.jsonPrimitive?.contentOrNullSafe()) {
            "discovery_probe" ->
                runCatching { json.decodeFromString<DiscoveryProbe>(text) }.getOrNull()
            "discovery_offer" ->
                runCatching { json.decodeFromString<DiscoveryOffer>(text) }.getOrNull()
            "discovery_response" ->
                runCatching { json.decodeFromString<DiscoveryResponse>(text) }.getOrNull()
            "discovery_select" ->
                runCatching { json.decodeFromString<DiscoverySelect>(text) }.getOrNull()
            "discovery_select_ack" ->
                runCatching { json.decodeFromString<DiscoverySelectAck>(text) }.getOrNull()
            else -> null
        }
        return message?.takeIf { it.isValid() }
    }

    fun encode(message: DiscoveryProbe): String = json.encodeToString(DiscoveryProbe.serializer(), message)

    fun encode(message: DiscoveryResponse): String = json.encodeToString(DiscoveryResponse.serializer(), message)

    fun encode(message: DiscoverySelectAck): String = json.encodeToString(DiscoverySelectAck.serializer(), message)

    private fun kotlinx.serialization.json.JsonPrimitive.contentOrNullSafe(): String? =
        if (isString) content else null

    private fun DiscoveryMessage.isValid(): Boolean {
        val schemaVersion = when (this) {
            is DiscoveryProbe -> schemaVersion
            is DiscoveryOffer -> schemaVersion
            is DiscoveryResponse -> schemaVersion
            is DiscoverySelect -> schemaVersion
            is DiscoverySelectAck -> schemaVersion
        }
        if (schemaVersion != DISCOVERY_SCHEMA_VERSION) return false

        return when (this) {
            is DiscoveryProbe -> deviceId.isValidDeviceId()
            is DiscoveryOffer -> wsPort.isValidWsPort() && token.isValidPairingToken()
            is DiscoveryResponse -> deviceId.isValidDeviceId()
            is DiscoverySelect ->
                deviceId.isValidDeviceId() && wsPort.isValidWsPort() && token.isValidPairingToken()
            is DiscoverySelectAck -> deviceId.isValidDeviceId()
        }
    }

    private fun Int.isValidWsPort(): Boolean = this in 1..65_535

    private fun String.isValidPairingToken(): Boolean =
        length == 6 && all { it in '0'..'9' }

    private fun String.isValidDeviceId(): Boolean =
        isNotBlank() && length <= DISCOVERY_DEVICE_ID_MAX_LENGTH
}

/** IPv4アドレスとプレフィックス長から、そのサブネットのdirected broadcastを求める。 */
fun ipv4DirectedBroadcast(address: InetAddress, prefixLength: Int): InetAddress? {
    val bytes = address.address
    if (bytes.size != 4 || prefixLength !in 0..30) return null
    val result = bytes.copyOf()
    for (bit in prefixLength until 32) {
        val byteIndex = bit / 8
        val bitInByte = 7 - bit % 8
        result[byteIndex] = (result[byteIndex].toInt() or (1 shl bitInByte)).toByte()
    }
    return InetAddress.getByAddress(result)
}

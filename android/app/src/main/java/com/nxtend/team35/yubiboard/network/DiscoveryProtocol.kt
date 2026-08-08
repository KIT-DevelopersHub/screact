package com.nxtend.team35.yubiboard.network

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Screact ゼロコンフィグ・ペアリングの UDP 発見プロトコル。
 * Desktop が discovery_offer をブロードキャストし、待受中の Android が
 * discovery_response をユニキャスト返信、Desktop が選んだ1台にだけ
 * discovery_select を送る。select を受けた端末は同梱 token で WebSocket
 * (/ws/v1/input) へ自動接続する（6桁コードの手入力を廃止）。
 */
const val DISCOVERY_APP = "screact"
const val DISCOVERY_PORT = 8766
const val DISCOVERY_SCHEMA_VERSION = 1

sealed interface DiscoveryMessage

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
        return when (obj["messageType"]?.jsonPrimitive?.contentOrNullSafe()) {
            "discovery_offer" ->
                runCatching { json.decodeFromString<DiscoveryOffer>(text) }.getOrNull()
            "discovery_response" ->
                runCatching { json.decodeFromString<DiscoveryResponse>(text) }.getOrNull()
            "discovery_select" ->
                runCatching { json.decodeFromString<DiscoverySelect>(text) }.getOrNull()
            else -> null
        }
    }

    fun encode(message: DiscoveryResponse): String = json.encodeToString(DiscoveryResponse.serializer(), message)

    private fun kotlinx.serialization.json.JsonPrimitive.contentOrNullSafe(): String? =
        if (isString) content else null
}

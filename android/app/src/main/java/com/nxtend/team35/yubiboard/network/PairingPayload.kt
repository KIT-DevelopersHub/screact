package com.nxtend.team35.yubiboard.network

import java.net.URI

/**
 * `screact://pair?...` の QR / ディープリンク接続ペイロードのデコーダ（Kotlin 版）。
 *
 * デスクトップの真実の源 `desktop/lib/net/pairing_payload.dart` の `tryParse` 意味論を
 * 移植したもの。QR で運んでも認証は `hello.pairingToken`（6桁）1本のまま。1個の URI に
 * LAN 直結情報（host/port）とリレー情報（relay/room）の両方を載せられ、スマホは LAN 直結を
 * 先に試す。
 *
 * 単体テスト可能にするため android.net.Uri ではなく java.net.URI を使う。
 */
data class PairingPayload(
    val version: Int = CURRENT_VERSION,
    val pairingToken: String,
    val lanHost: String? = null,
    val lanPort: Int? = null,
    val relayUrl: String? = null,
    val relayRoom: String? = null,
    /** QR の有効期限（UNIX 秒）。過ぎたら PC は再生成・スマホは失効表示。 */
    val expiresAt: Long? = null,
) {
    /** LAN 直結の接続先が揃っているか（host と有効な port）。 */
    val hasLanDirect: Boolean
        get() = !lanHost.isNullOrEmpty() && isValidPort(lanPort)

    /** リレー経由の接続先が揃っているか（relay と room）。 */
    val hasRelay: Boolean
        get() = !relayUrl.isNullOrEmpty() && !relayRoom.isNullOrEmpty()

    /** `exp` を過ぎているか（境界＝失効扱い）。exp が無ければ常に false。 */
    fun isExpired(nowEpochSec: Long): Boolean =
        expiresAt != null && nowEpochSec >= expiresAt

    companion object {
        const val SCHEME = "screact"

        /** URI の authority（`screact://pair?...`）。 */
        const val AUTHORITY = "pair"

        /** 現行ペイロード版数。未知版数の QR は受理しない。 */
        const val CURRENT_VERSION = 1

        private val TOKEN_REGEX = Regex("^\\d{6}$")

        private fun isValidToken(token: String): Boolean = TOKEN_REGEX.matches(token)

        private fun isValidPort(port: Int?): Boolean = port != null && port in 1..65535

        /**
         * `screact://pair?...` をパースする。不正・未知版数・接続先不明は null。
         * pairing_payload.dart の tryParse と同じ意味論。
         */
        fun tryParse(input: String): PairingPayload? {
            val uri = try {
                URI(input.trim())
            } catch (_: Exception) {
                return null
            }
            if (uri.scheme != SCHEME) return null
            // java.net.URI では `screact://pair?...` の `pair` は authority/host に入る。
            val authority = uri.host ?: uri.authority
            if (authority != AUTHORITY) return null

            val query = parseQuery(uri.rawQuery)

            val version = query["v"]?.toIntOrNull()
            if (version != CURRENT_VERSION) return null // 未知/欠落版数は弾く

            val token = query["t"]
            if (token == null || !isValidToken(token)) return null

            val host = query["host"]
            val port = query["port"]?.toIntOrNull()
            val relay = query["relay"]
            val room = query["room"]

            // host があるなら port も有効でなければ整合しない。
            val hasHost = !host.isNullOrEmpty()
            if (hasHost && !isValidPort(port)) return null
            // relay があるなら room も要る。
            val hasRelay = !relay.isNullOrEmpty()
            if (hasRelay && room.isNullOrEmpty()) return null

            val lanOk = hasHost && isValidPort(port)
            val relayOk = hasRelay && !room.isNullOrEmpty()
            // LAN もリレーも無いなら接続先が無く無効。
            if (!lanOk && !relayOk) return null

            val exp = query["exp"]?.toLongOrNull()

            return PairingPayload(
                version = CURRENT_VERSION,
                pairingToken = token,
                lanHost = if (lanOk) host else null,
                lanPort = if (lanOk) port else null,
                relayUrl = if (relayOk) relay else null,
                relayRoom = if (relayOk) room else null,
                expiresAt = exp,
            )
        }

        /** `a=1&b=2` 形式のクエリを、パーセントデコードしつつ map 化する。 */
        private fun parseQuery(rawQuery: String?): Map<String, String> {
            if (rawQuery.isNullOrEmpty()) return emptyMap()
            val result = LinkedHashMap<String, String>()
            for (pair in rawQuery.split('&')) {
                if (pair.isEmpty()) continue
                val idx = pair.indexOf('=')
                if (idx < 0) {
                    result[decode(pair)] = ""
                } else {
                    val key = decode(pair.substring(0, idx))
                    val value = decode(pair.substring(idx + 1))
                    if (!result.containsKey(key)) result[key] = value
                }
            }
            return result
        }

        private fun decode(value: String): String = try {
            java.net.URLDecoder.decode(value, "UTF-8")
        } catch (_: Exception) {
            value
        }
    }
}

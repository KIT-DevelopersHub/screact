package com.nxtend.team35.yubiboard.settings

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.nxtend.team35.yubiboard.network.ConnectionConfig
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class TrustedConnection(
    val host: String,
    val port: Int,
    val resumeToken: String,
)

interface TrustedConnectionValues {
    fun getString(key: String): String?
    fun getInt(key: String, defaultValue: Int): Int
    fun put(values: Map<String, Any>)
    fun remove(keys: Set<String>)
}

class SharedPreferencesTrustedConnectionValues(
    private val preferences: SharedPreferences,
) : TrustedConnectionValues {
    override fun getString(key: String): String? = preferences.getString(key, null)

    override fun getInt(key: String, defaultValue: Int): Int =
        preferences.getInt(key, defaultValue)

    override fun put(values: Map<String, Any>) {
        preferences.edit().apply {
            values.forEach { (key, value) ->
                when (value) {
                    is String -> putString(key, value)
                    is Int -> putInt(key, value)
                    else -> error("Unsupported preference value for $key")
                }
            }
        }.apply()
    }

    override fun remove(keys: Set<String>) {
        preferences.edit().apply { keys.forEach(::remove) }.apply()
    }
}

interface ResumeTokenProtector {
    fun protect(token: String): String
    fun unprotect(protectedToken: String): String
}

class AndroidKeystoreResumeTokenProtector : ResumeTokenProtector {
    override fun protect(token: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        return listOf(
            FORMAT_VERSION,
            cipher.iv.encodeBase64(),
            cipher.doFinal(token.toByteArray(Charsets.UTF_8)).encodeBase64(),
        ).joinToString(":")
    }

    override fun unprotect(protectedToken: String): String {
        val parts = protectedToken.split(':')
        require(parts.size == 3 && parts[0] == FORMAT_VERSION) { "Unsupported token format" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            getOrCreateKey(),
            GCMParameterSpec(GCM_TAG_LENGTH_BITS, parts[1].decodeBase64()),
        )
        return cipher.doFinal(parts[2].decodeBase64()).toString(Charsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }

    private fun ByteArray.encodeBase64(): String =
        Base64.encodeToString(this, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)

    private fun String.decodeBase64(): ByteArray =
        Base64.decode(this, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "yubiboard_resume_token_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_LENGTH_BITS = 128
        private const val FORMAT_VERSION = "v1"
    }
}

class TrustedConnectionStore(
    private val values: TrustedConnectionValues,
    private val protector: ResumeTokenProtector,
) {
    fun load(): TrustedConnection? {
        val host = values.getString(KEY_HOST) ?: return null
        val protectedToken = values.getString(KEY_RESUME_TOKEN) ?: return null
        val port = values.getInt(KEY_PORT, -1)
        return runCatching {
            TrustedConnection(host, port, protector.unprotect(protectedToken)).also {
                require(ConnectionConfig(it.host, it.port, resumeToken = it.resumeToken).validate() == null)
            }
        }.getOrElse {
            clear()
            null
        }
    }

    fun save(host: String, port: Int, resumeToken: String): Boolean = runCatching {
        require(ConnectionConfig(host, port, resumeToken = resumeToken).validate() == null)
        values.put(
            mapOf(
                KEY_HOST to host,
                KEY_PORT to port,
                KEY_RESUME_TOKEN to protector.protect(resumeToken),
            ),
        )
    }.isSuccess

    fun clear() = values.remove(TRUSTED_KEYS)

    companion object {
        const val KEY_HOST = "trusted_host"
        const val KEY_PORT = "trusted_port"
        const val KEY_RESUME_TOKEN = "trusted_resume_token"
        private val TRUSTED_KEYS = setOf(KEY_HOST, KEY_PORT, KEY_RESUME_TOKEN)
    }
}

class TrustedConnectionCoordinator(
    private val store: TrustedConnectionStore,
    private val connect: (ConnectionConfig, Boolean) -> Unit,
) {
    fun autoConnect(): Boolean {
        val trusted = store.load() ?: return false
        connect(
            ConnectionConfig(
                host = trusted.host,
                port = trusted.port,
                resumeToken = trusted.resumeToken,
            ),
            true,
        )
        return true
    }

    fun save(host: String, port: Int, resumeToken: String): Boolean =
        store.save(host, port, resumeToken)

    fun forget() = store.clear()

    fun savedConnection(): TrustedConnection? = store.load()
}

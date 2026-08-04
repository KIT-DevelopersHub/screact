package com.nxtend.team35.yubiboard.protocol

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

object ProtocolCodec {
    val json = Json {
        encodeDefaults = true
        explicitNulls = false
        ignoreUnknownKeys = true
    }

    fun encode(message: HelloMessage): String = json.encodeToString(message)

    fun encode(message: HandFrameMessage): String = json.encodeToString(message)

    fun encode(message: CalibrationMarkersMessage): String = json.encodeToString(message)

    fun encode(message: HeartbeatMessage): String = json.encodeToString(message)

    fun decodeServerMessage(text: String): ServerMessage? {
        val messageType = json.parseToJsonElement(text)
            .jsonObject["messageType"]
            ?.jsonPrimitive
            ?.content
            ?: return null
        return when (messageType) {
            "hello_ack" -> json.decodeFromString<HelloAckMessage>(text)
            "control_message" -> json.decodeFromString<ControlMessage>(text)
            else -> null
        }
    }
}

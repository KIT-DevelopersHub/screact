package com.nxtend.team35.yubiboard.protocol

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolCodecTest {
    @Test
    fun `hello contains the versioned capabilities`() {
        val encoded = ProtocolCodec.encode(
            HelloMessage(
                deviceId = "android-test",
                clientVersion = "0.1.0",
                pairingToken = "482731",
            ),
        )
        val root = ProtocolCodec.json.parseToJsonElement(encoded).jsonObject

        assertEquals(1, root.getValue("schemaVersion").jsonPrimitive.content.toInt())
        assertEquals("hello", root.getValue("messageType").jsonPrimitive.content)
        assertTrue(encoded.contains("hand_landmarks_21"))
    }

    @Test
    fun `detected frame preserves all 21 landmark arrays`() {
        val landmarks = List(21) { index -> listOf(index / 100f, 0.5f, -0.01f) }
        val encoded = ProtocolCodec.encode(
            HandFrameMessage(
                sessionId = "session-test",
                frameId = 7,
                capturedAtMonotonicMs = 1234,
                source = SourceInfo(640, 480),
                hand = HandPayload(
                    detected = true,
                    handedness = "RIGHT",
                    handednessScore = 0.98f,
                    landmarks = landmarks,
                ),
            ),
        )

        assertEquals(21, ProtocolCodec.json.parseToJsonElement(encoded)
            .jsonObject.getValue("hand").jsonObject
            .getValue("landmarks").toString().count { it == '[' } - 1)
    }

    @Test
    fun `undetected frame omits landmark-only fields`() {
        val encoded = ProtocolCodec.encode(
            HandFrameMessage(
                sessionId = "session-test",
                frameId = 8,
                capturedAtMonotonicMs = 1267,
                hand = HandPayload(detected = false),
            ),
        )

        assertTrue(encoded.contains("\"detected\":false"))
        assertTrue(!encoded.contains("landmarks"))
    }

    @Test
    fun `server messages tolerate additional fields`() {
        val decoded = ProtocolCodec.decodeServerMessage(
            """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"s1","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":true,"future":42}""",
        )

        assertTrue(decoded is HelloAckMessage)
        assertEquals("s1", (decoded as HelloAckMessage).sessionId)
    }

    @Test
    fun `unknown server message is ignored`() {
        assertNull(
            ProtocolCodec.decodeServerMessage(
                """{"schemaVersion":1,"messageType":"future_message"}""",
            ),
        )
    }
}

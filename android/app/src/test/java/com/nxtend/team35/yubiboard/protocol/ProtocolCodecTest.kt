package com.nxtend.team35.yubiboard.protocol

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonArray
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
        assertTrue(encoded.contains("multi_hand_landmarks_21"))
        assertTrue(encoded.contains("stable_hand_track_id"))
        assertTrue(encoded.contains("\"maxHands\":2"))
        assertTrue(encoded.contains("\"interactionProfile\":\"two_users_two_active_hands\""))
        assertTrue(encoded.contains("calibration_status"))
        assertTrue(encoded.contains("hello_error"))
        assertTrue(encoded.contains("trusted_reconnect"))
        assertTrue(encoded.contains("\"pairingToken\":\"482731\""))
        assertTrue(!encoded.contains("resumeToken"))
    }

    @Test
    fun `trusted hello sends resume token without pairing token`() {
        val encoded = ProtocolCodec.encode(
            HelloMessage(
                deviceId = "android-test",
                clientVersion = "0.1.0",
                resumeToken = "opaque-resume-token",
            ),
        )

        assertTrue(encoded.contains("\"resumeToken\":\"opaque-resume-token\""))
        assertTrue(!encoded.contains("pairingToken"))
    }

    @Test
    fun `hello authentication fields are exclusive`() {
        assertTrue(
            runCatching {
                HelloMessage(deviceId = "android-test", clientVersion = "0.1.0")
            }.isFailure,
        )
        assertTrue(
            runCatching {
                HelloMessage(
                    deviceId = "android-test",
                    clientVersion = "0.1.0",
                    pairingToken = "123456",
                    resumeToken = "resume",
                )
            }.isFailure,
        )
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
                hands = listOf(
                    TrackedHandPayload(
                        trackId = 7,
                        handedness = "RIGHT",
                        handednessScore = 0.98f,
                        landmarks = landmarks,
                    ),
                ),
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
                hands = emptyList(),
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

    @Test
    fun `hello acknowledgement exposes issued resume token`() {
        val decoded = ProtocolCodec.decodeServerMessage(
            """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"s1","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":true,"resumeToken":"issued-token","future":42}""",
        ) as HelloAckMessage

        assertEquals("issued-token", decoded.resumeToken)
    }

    @Test
    fun `two hands share one frame and legacy hand copies the lowest track id`() {
        fun landmarks(x: Float) = List(21) { listOf(x, 0.5f, -0.01f) }
        val left = TrackedHandPayload(trackId = 7, landmarks = landmarks(0.2f))
        val right = TrackedHandPayload(trackId = 12, landmarks = landmarks(0.8f))
        val encoded = ProtocolCodec.encode(
            HandFrameMessage(
                sessionId = "session-test",
                frameId = 9,
                capturedAtMonotonicMs = 1300,
                hands = listOf(left, right),
                hand = HandPayload(detected = true, landmarks = left.landmarks),
            ),
        )
        val root = ProtocolCodec.json.parseToJsonElement(encoded).jsonObject

        assertEquals(2, root.getValue("hands").jsonArray.size)
        assertTrue(root.getValue("hand").toString().contains("[0.2,0.5,-0.01]"))
    }

    @Test
    fun `hello acknowledgement exposes accepted interaction profile`() {
        val decoded = ProtocolCodec.decodeServerMessage(
            """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"s1","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":false,"acceptedInteractionProfile":"two_users_two_active_hands"}""",
        ) as HelloAckMessage

        assertEquals("two_users_two_active_hands", decoded.acceptedInteractionProfile)
    }

    @Test
    fun `hello error and calibration status are decoded`() {
        val helloError = ProtocolCodec.decodeServerMessage(
            """{"schemaVersion":1,"messageType":"hello_error","code":"pairing_code_mismatch","retryable":false}""",
        )
        val calibration = ProtocolCodec.decodeServerMessage(
            """{"schemaVersion":1,"messageType":"calibration_status","sessionId":"s1","status":"retry_required","reason":"invalid_geometry"}""",
        )

        assertTrue(helloError is HelloErrorMessage)
        assertEquals("pairing_code_mismatch", (helloError as HelloErrorMessage).code)
        assertTrue(calibration is CalibrationStatusMessage)
        assertEquals("retry_required", (calibration as CalibrationStatusMessage).status)
    }
}

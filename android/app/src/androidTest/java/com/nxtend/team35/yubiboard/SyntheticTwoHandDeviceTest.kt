package com.nxtend.team35.yubiboard

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Opt-in physical-device smoke test for the PC mock server.
 *
 * This test is skipped in ordinary CI. Run it with mockHost, mockPort, and mockToken
 * instrumentation arguments while tools/mock-websocket-server.ps1 is listening.
 */
class SyntheticTwoHandDeviceTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun sendsSyntheticTwoHandFramesToPcMock() {
        val arguments = InstrumentationRegistry.getArguments()
        val host = arguments.getString("mockHost").orEmpty()
        val port = arguments.getString("mockPort").orEmpty()
        val token = arguments.getString("mockToken").orEmpty()
        assumeTrue(
            "Physical-device mock connection arguments were not supplied",
            host.isNotBlank() && port.isNotBlank() && token.isNotBlank(),
        )

        composeRule.waitUntil(timeoutMillis = 20_000) {
            composeRule.onAllNodesWithText("接続する").fetchSemanticsNodes().isNotEmpty() ||
                composeRule.onAllNodesWithText("PCから切断").fetchSemanticsNodes().isNotEmpty()
        }
        val alreadyConnected = composeRule.onAllNodesWithText("PCから切断")
            .fetchSemanticsNodes()
            .isNotEmpty()
        if (!alreadyConnected) {
            composeRule.onNodeWithTag("connection_host").performTextReplacement(host)
            composeRule.onNodeWithTag("connection_port").performTextReplacement(port)
            composeRule.onNodeWithTag("connection_token").performTextReplacement(token)
            composeRule.onNodeWithTag("connect_button").performClick()
        }

        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithText("PCから切断").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("PCから切断").assertIsDisplayed()
        composeRule.onNodeWithText("診断").performClick()
        composeRule.onNodeWithText("デバッグ診断").assertIsDisplayed()

        composeRule.onNodeWithText("疑似2手連続").performClick()
        composeRule.waitForIdle()
        Thread.sleep(3_500)
    }
}

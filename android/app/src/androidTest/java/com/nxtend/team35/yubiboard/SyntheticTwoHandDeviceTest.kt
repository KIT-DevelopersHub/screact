package com.nxtend.team35.yubiboard

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
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
            composeRule.onAllNodesWithTag("show_manual_connection").fetchSemanticsNodes().isNotEmpty() ||
                composeRule.onAllNodesWithText("操作できます！").fetchSemanticsNodes().isNotEmpty()
        }
        val alreadyConnected = composeRule.onAllNodesWithText("操作できます！")
            .fetchSemanticsNodes()
            .isNotEmpty()
        if (!alreadyConnected) {
            composeRule.onNodeWithTag("show_manual_connection").performClick()
            composeRule.onNodeWithTag("connection_host").performTextReplacement(host)
            composeRule.onNodeWithTag("connection_port").performTextReplacement(port)
            composeRule.onNodeWithTag("connection_token").performTextReplacement(token)
            composeRule.onNodeWithTag("connect_button").performClick()
        }

        composeRule.waitUntil(timeoutMillis = 15_000) {
            composeRule.onAllNodesWithText("操作できます！").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("操作できます！").assertIsDisplayed()
        composeRule.activity.startSyntheticTwoHandStreamForTest()
        composeRule.waitForIdle()
        Thread.sleep(3_500)
    }
}

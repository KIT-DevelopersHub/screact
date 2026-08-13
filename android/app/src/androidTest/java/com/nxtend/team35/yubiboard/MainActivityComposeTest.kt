package com.nxtend.team35.yubiboard

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Rule
import org.junit.Test

class MainActivityComposeTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun productionLayoutIsSharedByProductionAndDebugModes() {
        // OEM backup/restore may preserve the last experience preference after reinstalling.
        if (composeRule.onAllNodesWithText("デバッグへ戻る").fetchSemanticsNodes().isNotEmpty()) {
            composeRule.onNodeWithText("PCに接続").assertIsDisplayed()
            composeRule.onNodeWithText("接続する").assertIsDisplayed()
            composeRule.onNodeWithText("デバッグへ戻る").performClick()
        }

        composeRule.onNodeWithText("PCに接続").assertIsDisplayed()
        composeRule.onNodeWithText("DEBUG・最大2手の全骨格を表示中").assertIsDisplayed()
        composeRule.onNodeWithText("詳細設定").performClick()

        composeRule.onNodeWithText("デバッグモード").assertIsDisplayed()
        composeRule.onNodeWithText("適用").assertIsDisplayed()
    }
}

package com.nxtend.team35.yubiboard

import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasNoScrollAction
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class MainActivityComposeTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun appAlwaysUsesProductionUiWithoutDebugControlsOrScrolling() {
        composeRule.onNodeWithTag("production_camera_preview").assertIsDisplayed()
        composeRule.onNodeWithTag("production_guide_content").assert(hasNoScrollAction())
        assertDebugControlsAbsent()

        composeRule.onNodeWithTag("production_help_button").assertIsDisplayed().performClick()
        composeRule.onNodeWithText("設定・ヘルプ").assertIsDisplayed()
        assertDebugControlsAbsent()
    }

    private fun assertDebugControlsAbsent() {
        listOf("デバッグへ戻る", "デバッグ画面を開く", "デバッグモード").forEach { label ->
            assertTrue(
                "$label が本番UIに残っています",
                composeRule.onAllNodesWithText(label).fetchSemanticsNodes().isEmpty(),
            )
        }
    }
}

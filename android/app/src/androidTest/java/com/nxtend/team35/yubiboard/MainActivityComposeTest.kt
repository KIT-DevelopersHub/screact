package com.nxtend.team35.yubiboard

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Rule
import org.junit.Test

class MainActivityComposeTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun primaryConnectionActionAndRuntimeModeSettingAreVisible() {
        composeRule.onNodeWithText("PCへ接続").assertIsDisplayed()
        composeRule.onNodeWithText("設定").performClick()

        composeRule.onNodeWithText("デバッグモード").assertIsDisplayed()
        composeRule.onNodeWithText("適用").assertIsDisplayed()
    }
}

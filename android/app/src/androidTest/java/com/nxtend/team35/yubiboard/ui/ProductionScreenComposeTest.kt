package com.nxtend.team35.yubiboard.ui

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasNoScrollAction
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import kotlin.math.abs

class ProductionScreenComposeTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Before
    fun keepTestHostLandscape() {
        composeRule.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        }
    }

    @Test
    fun connectionFormKeepsPreviewCharacterAndConnectionActionWithoutScroll() {
        var connectClicked = false
        setScreen(
            state = ProductionUiState(camera = CameraUiState.READY),
            onConnect = { _, _, _ -> connectClicked = true; null },
        )

        composeRule.onNodeWithTag("production_camera_preview").assertIsDisplayed()
        composeRule.onNodeWithTag("production_character").assertIsDisplayed()
        composeRule.onNodeWithText("PCに接続").assertIsDisplayed()
        composeRule.onNodeWithText("接続情報はPCアプリに\n表示されています！").assertIsDisplayed()
        val hostField = composeRule.onNodeWithTag("host_field")
        val portField = composeRule.onNodeWithTag("port_field")
        val pairingCodeField = composeRule.onNodeWithTag("pairing_code_field")
        assertNodeFitsViewport(hostField, "ホスト入力")
        assertNodeFitsViewport(portField, "ポート入力")
        assertNodeFitsViewport(pairingCodeField, "コード入力")
        hostField.assertIsDisplayed()
        portField.assertIsDisplayed()
        pairingCodeField.assertIsDisplayed()
        assertGuideFitsViewport("接続フォーム")
        assertTitleCentered("接続フォーム")
        val connectButton = composeRule.onNodeWithTag("connect_button")
        assertNodeFitsViewport(connectButton, "接続ボタン")
        connectButton.assertIsDisplayed()
        connectButton.performClick()

        assertTrue(connectClicked)
    }

    @Test
    fun activeTrackingKeepsDisconnectAndRemovesDebugActions() {
        var disconnectClicked = false
        setScreen(
            state = connectedState().copy(tracking = TrackingUiState.TRACKING),
            onDisconnect = { disconnectClicked = true },
        )

        composeRule.onNodeWithText("手を検出しています").assertIsDisplayed()
        composeRule.onNodeWithText("PCに接続済みです。").assertIsDisplayed()
        composeRule.onNodeWithText("PCから切断").assertIsDisplayed().performClick()
        assertDebugControlsAbsent()
        assertGuideFitsViewport("手の追跡中")

        assertTrue(disconnectClicked)
    }

    @Test
    fun idleReadyMatchesSimpleGuideAndHelpHasNoDebugMode() {
        var disconnectClicked = false
        setScreen(
            state = connectedState().copy(tracking = TrackingUiState.READY_NO_HAND),
            onDisconnect = { disconnectClicked = true },
        )

        composeRule.onNodeWithText("操作できます！").assertIsDisplayed()
        composeRule.onNodeWithText("カメラの前に手を映してください。").assertIsDisplayed()
        assertTrue(composeRule.onAllNodesWithText("PCから切断").fetchSemanticsNodes().isEmpty())
        composeRule.onNodeWithTag("production_help_button").performClick()
        composeRule.onNodeWithText("PCから切断").assertIsDisplayed().performClick()

        assertTrue(disconnectClicked)
        assertDebugControlsAbsent()
    }

    @Test
    fun reconnectingCharacterStaysBelowBothRecoveryButtons() {
        var retryClicked = false
        var settingsClicked = false
        setScreen(
            state = ProductionUiState(
                camera = CameraUiState.READY,
                connection = ConnectionSnapshot(ConnectionStatus.RECONNECTING, retryInSeconds = 3),
            ),
            onRetryNow = { retryClicked = true },
            onChangeConnectionSettings = { settingsClicked = true },
        )

        composeRule.onNodeWithText("3秒後に再接続します").assertIsDisplayed()
        composeRule.onNodeWithText("PCとの接続が途切れました。").assertIsDisplayed()
        assertGuideFitsViewport("再接続")

        val character = composeRule.onNodeWithTag("production_character").getUnclippedBoundsInRoot()
        val retryButton = composeRule.onNodeWithTag("reconnect_now_button").getUnclippedBoundsInRoot()
        val settingsButton = composeRule
            .onNodeWithTag("reconnect_settings_button")
            .getUnclippedBoundsInRoot()
        assertFalse("キャラクターが再接続ボタンに重なっています", character.top < retryButton.bottom)
        assertFalse("キャラクターが設定変更ボタンに重なっています", character.top < settingsButton.bottom)

        composeRule.onNodeWithTag("reconnect_now_button").assertIsDisplayed().performClick()
        composeRule.onNodeWithTag("reconnect_settings_button").assertIsDisplayed().performClick()
        assertTrue(retryClicked)
        assertTrue(settingsClicked)
    }

    @Test
    fun placementKeepsTheProvidedFixingInstructions() {
        setScreen(
            connectedState().copy(
                captureMode = CaptureMode.CALIBRATION,
                calibration = CalibrationUiState.PlacementWaiting,
            ),
        )

        composeRule.onNodeWithText("スマホを固定してください").assertIsDisplayed()
        assertGuideFitsViewport("配置待ち")
    }

    @Test
    fun calibrationProgressKeepsTheDetectedMarkerCount() {
        setScreen(
            connectedState().copy(
                captureMode = CaptureMode.CALIBRATION,
                calibration = CalibrationUiState.FindingMarkers(2),
            ),
        )

        composeRule.onNodeWithText("4つのマーカーを映してください").assertIsDisplayed()
        composeRule.onNodeWithText("検出済み 2/4").assertIsDisplayed()
        assertGuideFitsViewport("位置合わせ")
    }

    @Test
    fun everyProductionStateFitsViewportWithoutScrolling() {
        val samples = productionStateLabSamples() + StateLabSample(
            label = "長い通知",
            state = ProductionUiState(
                camera = CameraUiState.READY,
                connection = ConnectionSnapshot(
                    ConnectionStatus.ERROR,
                    detail = "PCとの接続を確認し、IPアドレスとポート番号を入力し直してください。",
                ),
                notice = "ネットワーク接続を確認してから、もう一度お試しください。",
            ),
        )
        val currentState = mutableStateOf(samples.first().state)
        setScreenContent(stateProvider = { currentState.value })

        samples.forEach { sample ->
            composeRule.runOnIdle { currentState.value = sample.state }
            composeRule.waitForIdle()
            assertGuideFitsViewport(sample.label)
            assertStateEndpointDisplayed(sample.state)
            assertDebugControlsAbsent()
        }
    }

    @Test
    fun localConnectionErrorAlsoFitsWithoutScrolling() {
        setScreen(
            state = ProductionUiState(camera = CameraUiState.READY),
            onConnect = { _, _, _ ->
                "IPアドレス、ポート番号、6桁コードをもう一度確認してください。"
            },
        )

        val connectButton = composeRule.onNodeWithTag("connect_button")
        assertNodeFitsViewport(connectButton, "入力エラー前の接続ボタン")
        connectButton.assertIsDisplayed()
        connectButton.performClick()
        val errorNode = composeRule.onNodeWithText(
            "IPアドレス、ポート番号、6桁コードをもう一度確認してください。",
        )
        assertNodeFitsViewport(errorNode, "入力エラーメッセージ")
        errorNode.assertIsDisplayed()
        assertGuideFitsViewport("入力エラー")
    }

    private fun assertStateEndpointDisplayed(state: ProductionUiState) {
        composeRule.onNodeWithTag("production_title").assertIsDisplayed()
        assertTitleCentered(state.visualState().name)
        when (state.visualState()) {
            ProductionVisualState.CAMERA_PERMISSION ->
                composeRule.onNodeWithText("カメラを許可").assertIsDisplayed()
            ProductionVisualState.CAMERA_ERROR ->
                composeRule.onNodeWithText("カメラを再起動").assertIsDisplayed()
            ProductionVisualState.CONNECTION_FORM ->
                composeRule.onNodeWithTag("connect_button").assertIsDisplayed()
            ProductionVisualState.CONNECTION_PROGRESS -> {
                val action = if (state.stage() == ProductionStage.AUTO_CONNECTING) {
                    "接続先を変更"
                } else {
                    "キャンセル"
                }
                composeRule.onNodeWithText(action).assertIsDisplayed()
            }
            ProductionVisualState.RECONNECTING,
            ProductionVisualState.PLACEMENT ->
                composeRule.onNodeWithTag("production_character").assertIsDisplayed()
            ProductionVisualState.CALIBRATION_PROGRESS -> when (val calibration = state.calibration) {
                is CalibrationUiState.FindingMarkers ->
                    composeRule.onNodeWithText("検出済み ${calibration.found}/4").assertIsDisplayed()
                is CalibrationUiState.Stabilizing ->
                    composeRule.onNodeWithText(
                        "安定度 ${calibration.current}/${calibration.required}",
                    ).assertIsDisplayed()
                else -> composeRule.onNodeWithTag("production_character").assertIsDisplayed()
            }
            ProductionVisualState.READY_IDLE ->
                composeRule.onNodeWithText("カメラの前に手を映してください。").assertIsDisplayed()
            ProductionVisualState.READY_ACTIVE ->
                composeRule.onNodeWithText("PCから切断").assertIsDisplayed()
        }
    }

    private fun assertTitleCentered(label: String) {
        val viewport = composeRule
            .onNodeWithTag("production_guide_viewport")
            .getUnclippedBoundsInRoot()
        val title = composeRule
            .onNodeWithTag("production_title")
            .getUnclippedBoundsInRoot()
        val viewportCenter = (viewport.left.value + viewport.right.value) / 2f
        val titleCenter = (title.left.value + title.right.value) / 2f

        assertTrue(
            "$label: 見出しが中央からずれています (${abs(titleCenter - viewportCenter)}dp)",
            abs(titleCenter - viewportCenter) <= 1f,
        )
    }

    private fun assertNodeFitsViewport(node: SemanticsNodeInteraction, label: String) {
        val viewport = composeRule
            .onNodeWithTag("production_guide_viewport")
            .getUnclippedBoundsInRoot()
        val bounds = node.getUnclippedBoundsInRoot()
        val tolerance = 1.dp

        assertTrue("$label: 左端が画面外です ($bounds / $viewport)", bounds.left >= viewport.left - tolerance)
        assertTrue("$label: 上端が画面外です ($bounds / $viewport)", bounds.top >= viewport.top - tolerance)
        assertTrue("$label: 右端が画面外です ($bounds / $viewport)", bounds.right <= viewport.right + tolerance)
        assertTrue("$label: 下端が画面外です ($bounds / $viewport)", bounds.bottom <= viewport.bottom + tolerance)
    }

    private fun assertGuideFitsViewport(label: String) {
        val viewport = composeRule
            .onNodeWithTag("production_guide_viewport")
            .getUnclippedBoundsInRoot()
        val contentNode = composeRule.onNodeWithTag("production_guide_content")
        val content = contentNode.getUnclippedBoundsInRoot()
        val tolerance = 1.dp

        contentNode.assert(hasNoScrollAction())
        assertTrue("$label: 左端が画面外です", content.left >= viewport.left - tolerance)
        assertTrue("$label: 上端が画面外です", content.top >= viewport.top - tolerance)
        assertTrue("$label: 右端が画面外です", content.right <= viewport.right + tolerance)
        assertTrue("$label: 下端が画面外です", content.bottom <= viewport.bottom + tolerance)
    }

    private fun assertDebugControlsAbsent() {
        listOf("デバッグへ戻る", "デバッグ画面を開く", "デバッグモード").forEach { label ->
            assertTrue(
                "$label が残っています",
                composeRule.onAllNodesWithText(label).fetchSemanticsNodes().isEmpty(),
            )
        }
    }

    private fun connectedState() = ProductionUiState(
        camera = CameraUiState.READY,
        connection = ConnectionSnapshot(ConnectionStatus.CONNECTED),
        captureMode = CaptureMode.TRACKING,
    )

    private fun setScreen(
        state: ProductionUiState,
        onConnect: (String, String, String) -> String? = { _, _, _ -> null },
        onDisconnect: () -> Unit = {},
        onRetryNow: () -> Unit = {},
        onChangeConnectionSettings: () -> Unit = {},
    ) = setScreenContent(
        stateProvider = { state },
        onConnect = onConnect,
        onDisconnect = onDisconnect,
        onRetryNow = onRetryNow,
        onChangeConnectionSettings = onChangeConnectionSettings,
    )

    private fun setScreenContent(
        stateProvider: () -> ProductionUiState,
        onConnect: (String, String, String) -> String? = { _, _, _ -> null },
        onDisconnect: () -> Unit = {},
        onRetryNow: () -> Unit = {},
        onChangeConnectionSettings: () -> Unit = {},
    ) {
        composeRule.setContent {
            MaterialTheme {
                ProductionScreen(
                    state = stateProvider(),
                    savedHost = "127.0.0.1",
                    savedPort = 8080,
                    hasTrustedPc = false,
                    cameraPermissionPermanentlyDenied = false,
                    previewContent = { Box(Modifier.fillMaxSize()) },
                    onRequestCameraPermission = {},
                    onOpenSystemSettings = {},
                    onRetryCamera = {},
                    onConnect = onConnect,
                    onCancelConnection = {},
                    onDisconnect = onDisconnect,
                    onRetryNow = onRetryNow,
                    onChangeConnectionSettings = onChangeConnectionSettings,
                    onForgetTrustedPc = {},
                )
            }
        }
    }
}

package com.nxtend.team35.yubiboard.settings

data class AppSettings(
    val analysisWidth: Int = 1280,
    val analysisHeight: Int = 720,
    val maxHands: Int = 1,
    val minDetectionConfidence: Float = 0.5f,
    val minPresenceConfidence: Float = 0.5f,
    val minTrackingConfidence: Float = 0.5f,
    val maxSendFps: Int = 20,
    val debugModeEnabled: Boolean = false,
) {
    fun validate(): String? = when {
        (analysisWidth to analysisHeight) !in SUPPORTED_RESOLUTIONS -> "未対応の解析解像度です"
        maxHands !in 1..2 -> "操作する手の数は1または2です"
        minDetectionConfidence !in 0f..1f -> "検出信頼度は0.0〜1.0です"
        minPresenceConfidence !in 0f..1f -> "存在信頼度は0.0〜1.0です"
        minTrackingConfidence !in 0f..1f -> "追跡信頼度は0.0〜1.0です"
        maxSendFps !in 5..20 -> "送信fpsは5〜20です"
        else -> null
    }

    fun toggledResolution(): AppSettings = when (analysisWidth to analysisHeight) {
        1280 to 720 -> copy(analysisWidth = 960, analysisHeight = 540)
        960 to 540 -> copy(analysisWidth = 640, analysisHeight = 480)
        else -> copy(analysisWidth = 1280, analysisHeight = 720)
    }

    companion object {
        val SUPPORTED_RESOLUTIONS = setOf(
            640 to 480,
            960 to 540,
            1280 to 720,
            1920 to 1080,
        )
    }
}

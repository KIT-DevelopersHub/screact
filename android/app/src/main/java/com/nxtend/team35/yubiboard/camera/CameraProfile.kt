package com.nxtend.team35.yubiboard.camera

import android.util.Size

enum class CameraProfile(val width: Int, val height: Int, val debugOnly: Boolean = false) {
    HD_720(1280, 720),
    QHD_540(960, 540),
    VGA_480(640, 480),
    FHD_1080(1920, 1080, debugOnly = true),
    ;

    val size: Size get() = Size(width, height)

    companion object {
        val productionOrder = listOf(HD_720, QHD_540, VGA_480)

        fun from(size: Size): CameraProfile = entries.firstOrNull {
            it.width == size.width && it.height == size.height
        } ?: HD_720
    }
}

data class CameraFrameInfo(
    val requestedProfile: CameraProfile,
    val actualWidth: Int,
    val actualHeight: Int,
    val rotationDegrees: Int,
    val cropLeft: Int,
    val cropTop: Int,
    val cropRight: Int,
    val cropBottom: Int,
)

package com.nxtend.team35.yubiboard.camera

import android.graphics.Bitmap
import android.graphics.Matrix
import androidx.camera.core.ImageProxy

fun ImageProxy.toCorrectedBitmap(): Bitmap {
    val rotationDegrees = imageInfo.rotationDegrees
    // CameraX's conversion handles the RGBA plane's channel order and stride.
    // Copying the plane buffer directly into ARGB_8888 produces corrupted colors
    // on devices whose CameraX buffer layout differs from Bitmap's native layout.
    val bitmap = try {
        toBitmap()
    } finally {
        close()
    }
    if (rotationDegrees == 0) return bitmap
    return Bitmap.createBitmap(
        bitmap,
        0,
        0,
        bitmap.width,
        bitmap.height,
        Matrix().apply { postRotate(rotationDegrees.toFloat()) },
        true,
    )
}

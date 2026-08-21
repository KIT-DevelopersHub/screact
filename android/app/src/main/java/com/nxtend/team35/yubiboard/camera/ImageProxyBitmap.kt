package com.nxtend.team35.yubiboard.camera

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Rect
import androidx.camera.core.ImageProxy

fun ImageProxy.toCorrectedBitmap(): Bitmap {
    val rotationDegrees = imageInfo.rotationDegrees
    val crop = Rect(cropRect)
    // CameraX's conversion handles the RGBA plane's channel order and stride.
    // Copying the plane buffer directly into ARGB_8888 produces corrupted colors
    // on devices whose CameraX buffer layout differs from Bitmap's native layout.
    val bitmap = try {
        toBitmap()
    } finally {
        close()
    }
    val cropped = if (
        crop.left == 0 && crop.top == 0 && crop.right == bitmap.width && crop.bottom == bitmap.height
    ) {
        bitmap
    } else {
        Bitmap.createBitmap(bitmap, crop.left, crop.top, crop.width(), crop.height())
    }
    if (rotationDegrees == 0) return cropped
    return Bitmap.createBitmap(
        cropped,
        0,
        0,
        cropped.width,
        cropped.height,
        Matrix().apply { postRotate(rotationDegrees.toFloat()) },
        true,
    )
}

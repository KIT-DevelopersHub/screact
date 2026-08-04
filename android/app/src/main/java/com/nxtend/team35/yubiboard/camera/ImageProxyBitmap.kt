package com.nxtend.team35.yubiboard.camera

import android.graphics.Bitmap
import android.graphics.Matrix
import androidx.camera.core.ImageProxy

fun ImageProxy.toCorrectedBitmap(): Bitmap {
    val rotationDegrees = imageInfo.rotationDegrees
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    try {
        planes[0].buffer.rewind()
        bitmap.copyPixelsFromBuffer(planes[0].buffer)
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

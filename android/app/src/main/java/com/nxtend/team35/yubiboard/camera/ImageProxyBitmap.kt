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
    val fullFrame =
        crop.left == 0 && crop.top == 0 && crop.right == bitmap.width && crop.bottom == bitmap.height

    // 回転が無ければ切り出しだけ（全域なら確保も不要）。
    if (rotationDegrees == 0) {
        if (fullFrame) return bitmap
        val cropped = Bitmap.createBitmap(bitmap, crop.left, crop.top, crop.width(), crop.height())
        if (cropped !== bitmap) bitmap.recycle()
        return cropped
    }

    // 切り出しと回転を1回の createBitmap で行い、中間 Bitmap の確保を1枚分省く。
    // 端末は通常 90/270 度回転するため、この経路が毎フレームの主コストになる。
    val matrix = Matrix().apply { postRotate(rotationDegrees.toFloat()) }
    val result = Bitmap.createBitmap(
        bitmap,
        crop.left,
        crop.top,
        crop.width(),
        crop.height(),
        matrix,
        true,
    )
    // 元 Bitmap（toBitmap の出力）はもう参照されないので即解放し、GC 前に
    // ネイティブメモリを返す（Large Object の GC 回数・PSS 増加を抑える）。
    if (result !== bitmap) bitmap.recycle()
    return result
}

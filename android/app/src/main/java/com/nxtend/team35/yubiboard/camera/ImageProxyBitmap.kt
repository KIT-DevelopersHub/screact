package com.nxtend.team35.yubiboard.camera

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Rect
import androidx.camera.core.ImageProxy

/**
 * 解析用ビットマップを取り出し、回転とミラーを補正して返す。
 *
 * Androidは前面カメラのプレビューを左右反転（ミラー）して表示するが、解析ストリーム
 * （手検出やArUcoに渡す画像）はミラーされない。補正しないと前面カメラ時だけランドマークの
 * x座標が見た目と左右逆になる。[mirror] が true のとき、回転後の表示座標系で水平反転し、
 * ミラープレビューと座標系を一致させる。背面カメラでは [mirror] は false で従来どおり。
 */
fun ImageProxy.toCorrectedBitmap(mirror: Boolean = false): Bitmap {
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
    if (rotationDegrees == 0 && !mirror) return cropped
    val matrix = Matrix().apply {
        if (rotationDegrees != 0) postRotate(rotationDegrees.toFloat())
        // 回転後（＝表示座標系）で水平反転し、前面カメラのミラープレビューに合わせる。
        if (mirror) postScale(-1f, 1f)
    }
    return Bitmap.createBitmap(
        cropped,
        0,
        0,
        cropped.width,
        cropped.height,
        matrix,
        true,
    )
}

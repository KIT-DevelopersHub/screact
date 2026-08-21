package com.nxtend.team35.yubiboard.vision

/**
 * 前面カメラのミラープレビューに合わせて、検出済み座標だけを水平反転する。
 *
 * 入力画像自体は反転しない。MediaPipe の入力Bitmap追加生成を避けるとともに、
 * ArUcoマーカーのビット列を鏡像にして検出不能にすることを防ぐ。
 */
internal fun LandmarkPoint.mirrorHorizontally(): LandmarkPoint = copy(x = 1f - x)

internal fun HandCandidate.mirrorHorizontally(): HandCandidate = copy(
    landmarks = landmarks.map(LandmarkPoint::mirrorHorizontally),
)

internal fun NormalizedPoint.mirrorHorizontally(): NormalizedPoint = copy(x = 1f - x)

internal fun DetectedMarker.mirrorHorizontally(): DetectedMarker = copy(
    center = center.mirrorHorizontally(),
    corners = corners.map(NormalizedPoint::mirrorHorizontally),
)

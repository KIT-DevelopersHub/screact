package com.nxtend.team35.yubiboard.ui

import android.app.Activity
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import coil.request.ImageRequest
import kotlinx.coroutines.delay

/**
 * 起動時のスプラッシュ。純白の全画面（システムバー領域含む）の中央に、画面幅の
 * 約半分に縮小したイントロ GIF を再生し、[durationMillis] 経過後に [onFinished] を
 * 呼んで本番 UI へ譲る。GIF 素材のワンループは約 2.7 秒なので、既定値は一巡ぶんに
 * 小さな余白を足した長さにしている。
 */
@Composable
fun SplashScreen(
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
    durationMillis: Long = SPLASH_DURATION_MS,
) {
    val context = LocalContext.current
    val view = LocalView.current

    // 白背景ではシステムバーのアイコンが白のままだと見えないため、スプラッシュ表示中
    // だけライトバー外観（＝アイコンをダーク表示）に切り替え、離脱時に元へ戻す。
    if (!view.isInEditMode) {
        DisposableEffect(Unit) {
            val window = (context as? Activity)?.window
            val controller = window?.let { WindowCompat.getInsetsController(it, view) }
            val previousLightStatus = controller?.isAppearanceLightStatusBars
            val previousLightNav = controller?.isAppearanceLightNavigationBars
            controller?.isAppearanceLightStatusBars = true
            controller?.isAppearanceLightNavigationBars = true
            onDispose {
                previousLightStatus?.let { controller?.isAppearanceLightStatusBars = it }
                previousLightNav?.let { controller?.isAppearanceLightNavigationBars = it }
            }
        }
    }

    // GIF を動かすため、GIF デコーダを備えた専用 ImageLoader を用意する。
    val imageLoader = remember {
        ImageLoader.Builder(context)
            .components {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    add(ImageDecoderDecoder.Factory())
                } else {
                    add(GifDecoder.Factory())
                }
            }
            .build()
    }

    LaunchedEffect(Unit) {
        delay(durationMillis)
        onFinished()
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(SPLASH_BACKGROUND),
        contentAlignment = Alignment.Center,
    ) {
        // 幅を画面の約 50% に固定。高さは GIF のアスペクト比から自動決定されるため、
        // 縦横とも従来（全画面 Fit）の約半分になり、周囲は白余白になる。
        AsyncImage(
            model = ImageRequest.Builder(context)
                .data("file:///android_asset/$SPLASH_ASSET")
                .build(),
            imageLoader = imageLoader,
            contentDescription = "Screact イントロアニメーション",
            contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxWidth(SPLASH_WIDTH_FRACTION),
        )
    }
}

private const val SPLASH_ASSET = "ScreactIntroAnimation.gif"
private const val SPLASH_DURATION_MS = 2_900L
private const val SPLASH_WIDTH_FRACTION = 0.5f

// スプラッシュらしい純白の全面背景。
private val SPLASH_BACKGROUND = Color(0xFFFFFFFF)

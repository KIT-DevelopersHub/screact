package com.nxtend.team35.yubiboard.ui

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import coil.request.ImageRequest
import kotlinx.coroutines.delay

/**
 * 起動時のスプラッシュ。中央にイントロ GIF を再生し、[durationMillis] 経過後に
 * [onFinished] を呼んで本番 UI へ譲る。GIF 素材のワンループは約 2.7 秒なので、
 * 既定値は一巡ぶんに小さな余白を足した長さにしている。
 */
@Composable
fun SplashScreen(
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
    durationMillis: Long = SPLASH_DURATION_MS,
) {
    val context = LocalContext.current
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
        AsyncImage(
            model = ImageRequest.Builder(context)
                .data("file:///android_asset/$SPLASH_ASSET")
                .build(),
            imageLoader = imageLoader,
            contentDescription = "Screact イントロアニメーション",
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
        )
    }
}

private const val SPLASH_ASSET = "ScreactIntroAnimation.gif"
private const val SPLASH_DURATION_MS = 2_900L

// 本番テーマの background と揃え、遷移時に黒画面が挟まらないようにする。
private val SPLASH_BACKGROUND = Color(0xFF101010)

package com.nxtend.team35.yubiboard.bench

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import android.widget.TextView
import com.nxtend.team35.yubiboard.network.ble.BleBenchPeripheral

/**
 * 経路比較（BLE / WebSocket）の計測専用画面。本番の画面からは入口を出さない。
 * adb から起動する（シェルだけが持つ DUMP 権限で保護している）:
 * `adb shell am start -n com.nxtend.team35.yubiboard/.bench.TransportBenchActivity --es mode ble`
 * `adb shell am start -n ... --es mode ws --ei port 8765`（事前に `adb reverse tcp:8765 tcp:8765`）
 * 手順は android/tools/ble-bench/README.md。
 */
class TransportBenchActivity : Activity() {
    companion object {
        const val LOG_TAG = "ScreactBench"
        private const val PERMISSION_REQUEST = 17
    }

    private lateinit var statusView: TextView
    private val handler = Handler(Looper.getMainLooper())
    private var ble: BleBenchPeripheral? = null
    private var ws: WebSocketBenchClient? = null
    private val log: (String) -> Unit = { Log.i(LOG_TAG, it) }

    private val refresh = object : Runnable {
        override fun run() {
            val stats = ble?.engine?.snapshot() ?: ws?.engine?.snapshot()
            val status = ble?.status ?: ws?.status ?: "idle"
            statusView.text = "Screact transport bench\nmode=${intent.getStringExtra("mode") ?: "ble"}\n" +
                "status=$status\nmtu=${ble?.mtu() ?: "-"}\n$stats"
            handler.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        statusView = TextView(this).apply { textSize = 16f; setPadding(32, 32, 32, 32) }
        setContentView(statusView)
        val missing = requiredPermissions().filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) startBench() else requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
        handler.post(refresh)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return
        if (grantResults.all { it == PackageManager.PERMISSION_GRANTED }) startBench()
        else log("permission denied: ${permissions.joinToString()}")
    }

    override fun onDestroy() {
        handler.removeCallbacks(refresh)
        ble?.stop()
        ws?.stop()
        ble = null
        ws = null
        log("bench activity destroyed")
        super.onDestroy()
    }

    private fun requiredPermissions(): List<String> =
        if (intent.getStringExtra("mode") == "ws") {
            emptyList()
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            emptyList()
        }

    private fun startBench() {
        when (intent.getStringExtra("mode") ?: "ble") {
            "ws" -> {
                val port = intent.getIntExtra("port", 8765)
                val host = intent.getStringExtra("host") ?: "127.0.0.1"
                ws = WebSocketBenchClient("ws://$host:$port/bench", log).also { it.start() }
            }
            else -> ble = BleBenchPeripheral(this, log).also { it.start() }
        }
    }
}

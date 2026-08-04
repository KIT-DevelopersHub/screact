package com.nxtend.team35.yubiboard

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.nxtend.team35.yubiboard.camera.CameraSession
import com.nxtend.team35.yubiboard.vision.DebugOverlayView
import com.nxtend.team35.yubiboard.vision.HandLandmarkerProcessor

class MainActivity : AppCompatActivity() {
    private lateinit var cameraSession: CameraSession
    private lateinit var handLandmarkerProcessor: HandLandmarkerProcessor
    private lateinit var cameraStatus: TextView
    private lateinit var permissionCard: MaterialCardView

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            showCamera()
        } else {
            showPermissionPrompt()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContentView(R.layout.activity_main)

        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.main)) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }

        cameraStatus = findViewById(R.id.camera_status)
        permissionCard = findViewById(R.id.permission_card)
        val debugOverlay = findViewById<DebugOverlayView>(R.id.debug_overlay)
        handLandmarkerProcessor = HandLandmarkerProcessor(
            context = this,
            onResult = { result ->
                runOnUiThread {
                    debugOverlay.setHandResult(result)
                    cameraStatus.text = if (result.detected) {
                        getString(
                            R.string.hand_detected,
                            result.framesPerSecond,
                            result.inferenceTimeMs,
                        )
                    } else {
                        getString(R.string.hand_not_detected, result.framesPerSecond)
                    }
                }
            },
            onError = {
                runOnUiThread { cameraStatus.setText(R.string.hand_landmarker_error) }
            },
        )
        cameraSession = CameraSession(
            context = this,
            lifecycleOwner = this,
            previewView = findViewById<PreviewView>(R.id.preview_view),
            onReady = { cameraStatus.setText(R.string.camera_ready) },
            onError = {
                cameraStatus.setText(R.string.camera_error)
                showPermissionPrompt()
            },
        )
        cameraSession.setFrameConsumer(handLandmarkerProcessor::process)

        findViewById<MaterialButton>(R.id.grant_permission_button).setOnClickListener {
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }

        if (hasCameraPermission()) showCamera() else showPermissionPrompt()
    }

    override fun onDestroy() {
        cameraSession.close()
        handLandmarkerProcessor.close()
        super.onDestroy()
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun showCamera() {
        permissionCard.visibility = View.GONE
        cameraStatus.setText(R.string.hand_searching)
        cameraSession.start()
    }

    private fun showPermissionPrompt() {
        permissionCard.visibility = View.VISIBLE
    }
}

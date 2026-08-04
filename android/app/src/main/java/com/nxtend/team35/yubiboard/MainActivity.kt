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
import androidx.lifecycle.ViewModelProvider
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.nxtend.team35.yubiboard.camera.CameraSession
import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.vision.DebugOverlayView
import com.nxtend.team35.yubiboard.vision.HandLandmarkerProcessor

class MainActivity : AppCompatActivity() {
    private lateinit var cameraSession: CameraSession
    private lateinit var handLandmarkerProcessor: HandLandmarkerProcessor
    private lateinit var viewModel: MainViewModel
    private lateinit var cameraStatus: TextView
    private lateinit var permissionCard: MaterialCardView
    private lateinit var connectionStatus: TextView
    private lateinit var modeStatus: TextView
    private lateinit var hostInput: TextInputEditText
    private lateinit var portInput: TextInputEditText
    private lateinit var tokenInput: TextInputEditText
    private lateinit var connectButton: MaterialButton
    private lateinit var disconnectButton: MaterialButton
    private lateinit var modeButton: MaterialButton

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
        connectionStatus = findViewById(R.id.connection_status)
        modeStatus = findViewById(R.id.mode_status)
        hostInput = findViewById(R.id.host_input)
        portInput = findViewById(R.id.port_input)
        tokenInput = findViewById(R.id.token_input)
        connectButton = findViewById(R.id.connect_button)
        disconnectButton = findViewById(R.id.disconnect_button)
        modeButton = findViewById(R.id.mode_button)
        viewModel = ViewModelProvider(this)[MainViewModel::class.java]
        hostInput.setText(viewModel.savedHost)
        portInput.setText(viewModel.savedPort.toString())

        val debugOverlay = findViewById<DebugOverlayView>(R.id.debug_overlay)
        handLandmarkerProcessor = HandLandmarkerProcessor(
            context = this,
            onResult = { result ->
                viewModel.submitHand(result)
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
        connectButton.setOnClickListener {
            val error = viewModel.connect(
                hostInput.text?.toString().orEmpty(),
                portInput.text?.toString().orEmpty(),
                tokenInput.text?.toString().orEmpty(),
            )
            if (error != null) connectionStatus.text = error
        }
        disconnectButton.setOnClickListener { viewModel.disconnect() }
        modeButton.setOnClickListener {
            val next = if (viewModel.mode.value == CaptureMode.CALIBRATION) {
                CaptureMode.TRACKING
            } else {
                CaptureMode.CALIBRATION
            }
            viewModel.setModeManually(next)
        }

        viewModel.connection.observe(this, ::renderConnection)
        viewModel.mode.observe(this, ::renderMode)
        viewModel.log.observe(this) { message ->
            if (!message.isNullOrBlank()) connectionStatus.text = message
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

    private fun renderConnection(snapshot: ConnectionSnapshot) {
        connectionStatus.text = when (snapshot.status) {
            ConnectionStatus.DISCONNECTED -> getString(R.string.connection_disconnected)
            ConnectionStatus.CONNECTING -> getString(R.string.connection_connecting)
            ConnectionStatus.AWAITING_ACK -> getString(R.string.connection_awaiting_ack)
            ConnectionStatus.CONNECTED -> getString(R.string.connection_connected)
            ConnectionStatus.RECONNECTING -> getString(
                R.string.connection_reconnecting,
                snapshot.retryInSeconds ?: 0,
            )
            ConnectionStatus.ERROR -> snapshot.detail ?: getString(R.string.connection_error)
        }
        val connectedOrBusy = snapshot.status != ConnectionStatus.DISCONNECTED &&
            snapshot.status != ConnectionStatus.ERROR
        connectButton.isEnabled = !connectedOrBusy
        disconnectButton.isEnabled = connectedOrBusy
    }

    private fun renderMode(mode: CaptureMode) {
        val isCalibration = mode == CaptureMode.CALIBRATION
        modeStatus.setText(if (isCalibration) R.string.mode_calibration else R.string.mode_tracking)
        modeButton.setText(
            if (isCalibration) R.string.switch_to_tracking else R.string.switch_to_calibration,
        )
    }
}

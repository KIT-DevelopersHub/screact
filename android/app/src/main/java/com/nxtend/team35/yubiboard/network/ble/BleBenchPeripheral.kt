package com.nxtend.team35.yubiboard.network.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import com.nxtend.team35.yubiboard.bench.BenchEngine
import com.nxtend.team35.yubiboard.bench.BenchTransport
import java.util.UUID
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * BLE の計測用 peripheral（GATT サーバ + advertising）。PC が central として接続する。
 * 手指フレームは FRAME（notify）、制御は CONTROL（write with response / notify）に分ける。
 * 権限 BLUETOOTH_ADVERTISE / BLUETOOTH_CONNECT が付与済みであることを呼び出し側で確かめる。
 */
@SuppressLint("MissingPermission")
class BleBenchPeripheral(
    private val context: Context,
    private val log: (String) -> Unit,
) : BenchTransport {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("6c8f0001-3c1e-4d7a-9b8e-5c2a7d1e0b17")
        val FRAME_UUID: UUID = UUID.fromString("6c8f0002-3c1e-4d7a-9b8e-5c2a7d1e0b17")
        val CONTROL_UUID: UUID = UUID.fromString("6c8f0003-3c1e-4d7a-9b8e-5c2a7d1e0b17")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val DEFAULT_MTU = 23
        private const val MAX_ATTRIBUTE_BYTES = 512
        private const val NOTIFY_TIMEOUT_MS = 2_000L
    }

    private val manager = context.getSystemService(BluetoothManager::class.java)
    private var server: BluetoothGattServer? = null
    private var advertiseCallback: AdvertiseCallback? = null
    @Volatile private var device: BluetoothDevice? = null
    @Volatile private var mtu = DEFAULT_MTU
    private val notifySent = Semaphore(0)
    @Volatile private var lastNotifyStatus = BluetoothGatt.GATT_SUCCESS
    private lateinit var frameCharacteristic: BluetoothGattCharacteristic
    private lateinit var controlCharacteristic: BluetoothGattCharacteristic
    val engine = BenchEngine(this, log = log)

    @Volatile var status: String = "idle"
        private set

    fun start(): Boolean {
        val adapter = manager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            status = "bluetooth off"
            log(status)
            return false
        }
        val gattServer = manager.openGattServer(context, callback)
        if (gattServer == null) {
            status = "openGattServer failed"
            log(status)
            return false
        }
        server = gattServer
        frameCharacteristic = BluetoothGattCharacteristic(
            FRAME_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        ).apply { addDescriptor(cccd()) }
        controlCharacteristic = BluetoothGattCharacteristic(
            CONTROL_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        ).apply { addDescriptor(cccd()) }
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(frameCharacteristic)
        service.addCharacteristic(controlCharacteristic)
        gattServer.addService(service)
        engine.start()
        startAdvertising()
        return true
    }

    fun stop() {
        engine.shutdown()
        advertiseCallback?.let { callback ->
            runCatching { manager?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(callback) }
            log("advertising stopped")
        }
        advertiseCallback = null
        device?.let { runCatching { server?.cancelConnection(it) } }
        runCatching { server?.close() }
        server = null
        status = "stopped"
    }

    // ATT の上限は MTU − 3 だが、Android は 1 属性値を 512 B までに制限している（MTU 517 でも 514 B は送れない）。
    override fun maxUnitBytes(): Int = minOf(mtu - 3, MAX_ATTRIBUTE_BYTES)

    override fun mtu(): Int = mtu

    override fun sendFrameUnit(bytes: ByteArray): Boolean = notify(frameCharacteristic, bytes)

    override fun sendControl(bytes: ByteArray): Boolean = notify(controlCharacteristic, bytes)

    private fun notify(characteristic: BluetoothGattCharacteristic, bytes: ByteArray): Boolean {
        val target = device ?: return false
        val gattServer = server ?: return false
        notifySent.drainPermits()
        val accepted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gattServer.notifyCharacteristicChanged(target, characteristic, false, bytes) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = bytes
            @Suppress("DEPRECATION")
            gattServer.notifyCharacteristicChanged(target, characteristic, false)
        }
        if (!accepted) return false
        if (!notifySent.tryAcquire(NOTIFY_TIMEOUT_MS, TimeUnit.MILLISECONDS)) return false
        return lastNotifyStatus == BluetoothGatt.GATT_SUCCESS
    }

    private fun cccd() = BluetoothGattDescriptor(
        CCCD_UUID,
        BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
    )

    private fun startAdvertising() {
        val advertiser = manager?.adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            status = "advertiser unavailable"
            log(status)
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        // 端末名は載せず、サービス UUID だけで見つけてもらう。
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                status = "advertising"
                log(status)
            }

            override fun onStartFailure(errorCode: Int) {
                status = "advertise failed: $errorCode"
                log(status)
            }
        }
        advertiseCallback = callback
        advertiser.startAdvertising(settings, data, callback)
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                this@BleBenchPeripheral.device = device
                mtu = DEFAULT_MTU
                this@BleBenchPeripheral.status = "connected"
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (this@BleBenchPeripheral.device == device) this@BleBenchPeripheral.device = null
                this@BleBenchPeripheral.status = "disconnected (status=$status)"
                notifySent.release()
            }
            log("connection state=$newState status=$status")
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            this@BleBenchPeripheral.mtu = mtu
            log("mtu=$mtu")
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            lastNotifyStatus = status
            notifySent.release()
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value)
            }
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor,
        ) {
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, byteArrayOf(0, 0))
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (characteristic.uuid != CONTROL_UUID) {
                if (responseNeeded) {
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, 0, null)
                }
                return
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
            engine.onControl(value)
        }
    }
}

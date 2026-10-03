package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BlePrivateService
import com.fzfstudio.ezw_ble.ble.models.BleSecurityGate
import com.fzfstudio.ezw_ble.ble.models.BluetoothGattStatus
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.mockito.Mockito

/**
 * 已 Bond 设备的服务发现由 Android 直接读取本地 attribute cache。对端固件改表后，若
 * Service Changed 晚于首个 GATT 请求到达，系统不会重新发现，cache 句柄会一直失效
 * （2026-10-02 vivo V2415 + G2 右腿 OTA 后，480 次 5403 写全部返回 GATT_INVALID_HANDLE）。
 *
 * 这里锁定 readiness 阶段的边界：ATT 句柄失效先刷新本端 cache，再按 CHARS_FAIL 终止，
 * 让下一次 attempt 走空中服务发现；它不是安全证据，不能进入授权恢复或安全恢复预算。
 */
class BleStaleAttributeCacheRecoveryTest {
    private val endpoint = "E4:4B:C7:90:4F:05"
    private val mainService = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5450")
    private val gateChars = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5403")
    private val writeChars = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5401")
    private val readChars = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5402")

    @Test
    fun `security gate invalid handle refreshes stale attribute cache before chars fail`() {
        val fixture = Fixture(gateConfig())
        val gateCharacteristic = characteristic(gateChars)
        // 5403 已按当前 exact owner 提交，回调到达时由 registry 认领。
        assertTrue(fixture.registry.start(fixture.owner, gateChars))

        fixture.callback.onCharacteristicWrite(
            fixture.gatt,
            gateCharacteristic,
            BluetoothGattStatus.GATT_INVALID_HANDLE,
        )

        assertEquals(listOf("staleCacheRecovery", "terminal:CHARS_FAIL"), fixture.events)
    }

    @Test
    fun `security gate authentication failure keeps security recovery without stale cache refresh`() {
        val fixture = Fixture(gateConfig())
        val gateCharacteristic = characteristic(gateChars)
        assertTrue(fixture.registry.start(fixture.owner, gateChars))

        fixture.callback.onCharacteristicWrite(fixture.gatt, gateCharacteristic, 5)

        assertEquals(
            listOf("authorizationRecovery", "securityFailure:5", "terminal:DISCONNECT_FROM_SYS"),
            fixture.events,
        )
    }

    @Test
    fun `security gate generic error stays chars fail without stale cache refresh`() {
        val fixture = Fixture(gateConfig())
        val gateCharacteristic = characteristic(gateChars)
        assertTrue(fixture.registry.start(fixture.owner, gateChars))

        fixture.callback.onCharacteristicWrite(fixture.gatt, gateCharacteristic, 133)

        assertEquals(listOf("terminal:CHARS_FAIL"), fixture.events)
    }

    @Test
    fun `cccd invalid handle refreshes stale attribute cache before chars fail`() {
        val fixture = Fixture(privateServiceConfig())
        val descriptor = fixture.startCccdWrite()

        fixture.callback.onDescriptorWrite(
            fixture.gatt,
            descriptor,
            BluetoothGattStatus.GATT_INVALID_HANDLE,
        )

        assertEquals(listOf("staleCacheRecovery", "terminal:CHARS_FAIL"), fixture.events)
    }

    @Test
    fun `cccd insufficient authorization keeps authorization recovery without stale cache refresh`() {
        val fixture = Fixture(privateServiceConfig())
        val descriptor = fixture.startCccdWrite()

        fixture.callback.onDescriptorWrite(
            fixture.gatt,
            descriptor,
            BluetoothGattStatus.GATT_INSUFFICIENT_AUTHORIZATION,
        )

        assertEquals(listOf("authorizationRecovery", "terminal:CHARS_FAIL"), fixture.events)
    }

    /** G2 新固件形态：5403 Gate 与主服务私有通道同属 5450。 */
    private fun gateConfig(): BleConfig = privateServiceConfig().copy(
        securityGate = BleSecurityGate(mainService.toString(), gateChars.toString()),
    )

    /** 不配置 Gate，服务发现后直接进入私有服务 CCCD readiness。 */
    private fun privateServiceConfig(): BleConfig = BleConfig.empty().copy(
        privateServices = listOf(
            BlePrivateService(
                mainService.toString(),
                writeChars = writeChars.toString(),
                readChars = readChars.toString(),
            ),
        ),
    )

    private fun characteristic(uuid: UUID): BluetoothGattCharacteristic =
        Mockito.mock(BluetoothGattCharacteristic::class.java).also {
            Mockito.`when`(it.uuid).thenReturn(uuid)
        }

    /** 真实 callback + 记录注入函数调用顺序；顺序本身就是“先刷新、后终止”的契约。 */
    private inner class Fixture(config: BleConfig) {
        val events = mutableListOf<String>()
        val gatt: BluetoothGatt = Mockito.mock(BluetoothGatt::class.java)
        val registry = BleAndroidSecurityGateAttemptRegistry()
        val owner = BleAndroidSecurityGateOwner(endpoint, 7L, 11L, 1L, gatt)
        val device = BleDevice(
            config,
            "Even G2_32_R_904F05",
            endpoint,
            "S211GABK070032",
            0,
            BleConnectState.SEARCH_SERVICE,
        )
        val callback: BleGattSessionCallback

        init {
            val peripheral = Mockito.mock(BluetoothDevice::class.java)
            Mockito.`when`(gatt.device).thenReturn(peripheral)
            Mockito.`when`(peripheral.address).thenReturn(endpoint)
            callback = BleGattSessionCallback(
                expectedUuid = endpoint,
                sessionGeneration = 7L,
                attemptGeneration = 11L,
                currentDeviceForGatt = { source, _ -> if (source === gatt) device else null },
                handleConnectState = { _, _, _, _ -> },
                recordTraceStep = { _, _, _, _, _, _ -> },
                recordTraceMtu = { _, _, _, _ -> },
                updateTraceRssi = { _, _ -> },
                markTraceRssiRequested = { },
                markTraceRssiFailed = { },
                recordPhysicalTrace = { _, _ -> },
                updateTracePhy = { _, _ -> },
                updateTraceRequestedPriority = { _, _, _ -> },
                recordTracePhyPolicy = { _, _, _, _ -> },
                onPhysicalConnected = { _, _ -> },
                onSessionTerminal = { _, state, _ -> events += "terminal:$state" },
                isBluetoothEnabled = { true },
                recoverInsufficientAuthorization = { _, _ -> events += "authorizationRecovery" },
                recoverStaleAttributeCache = { _, _ -> events += "staleCacheRecovery" },
                securityGateAttempts = registry,
                securityGateOwner = { owner },
                onSecurityGateFailure = { _, _, _, code ->
                    events += "securityFailure:$code"
                    BleAndroidSecurityRecoveryAction.RETRY
                },
                onSecurityGatePassed = { events += "securityPassed" },
                onSecurityGateUnavailable = { _, _ ->
                    events += "securityGateUnavailable"
                    false
                },
                consumeDisconnectingState = { null },
                onCharacteristicWriteComplete = { _, _, _, _ -> events += "businessWriteComplete" },
                activeG2OtaContextForEndpoint = { null },
                emitReceiveData = { },
                sendLog = { _, _ -> },
            )
        }

        /**
         * 走真实服务发现把 CCCD 放入串行队列并提交第一条写入。
         * 单测 android.jar 的 SDK_INT 为 0，callback 使用旧版 writeDescriptor(descriptor)。
         */
        fun startCccdWrite(): BluetoothGattDescriptor {
            val service = Mockito.mock(BluetoothGattService::class.java)
            val write = characteristic(writeChars)
            val read = characteristic(readChars)
            val descriptor = Mockito.mock(BluetoothGattDescriptor::class.java)
            Mockito.`when`(gatt.getService(mainService)).thenReturn(service)
            Mockito.`when`(service.getCharacteristic(writeChars)).thenReturn(write)
            Mockito.`when`(service.getCharacteristic(readChars)).thenReturn(read)
            Mockito.`when`(gatt.setCharacteristicNotification(read, true)).thenReturn(true)
            Mockito.`when`(read.getDescriptor(BleManager.cccdDescriptor)).thenReturn(descriptor)
            Mockito.`when`(descriptor.uuid).thenReturn(BleManager.cccdDescriptor)
            Mockito.`when`(descriptor.characteristic).thenReturn(read)
            @Suppress("DEPRECATION")
            Mockito.`when`(gatt.writeDescriptor(descriptor)).thenReturn(true)

            callback.onServicesDiscovered(gatt, BluetoothGatt.GATT_SUCCESS)
            assertEquals(emptyList(), events, "CCCD 写入提交前不得产生终态或恢复动作")
            return descriptor
        }
    }
}

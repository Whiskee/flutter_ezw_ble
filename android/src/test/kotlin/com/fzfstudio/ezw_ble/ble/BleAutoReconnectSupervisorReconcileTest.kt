package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.os.SystemClock
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectSource
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import org.mockito.Mockito

/**
 * Reconcile 的可执行 native 行为测试。
 *
 * 这里注入 Android GATT 边界，验证 task、GATT 与 session owner 的创建/复用/修复，
 * 避免 Dart 测试只通过源码字符串推断 native 行为。
 */
class BleAutoReconnectSupervisorReconcileTest {
    @Test
    fun `reconcile creates missing owner then reuses the exact healthy gatt`() {
        val fixture = Fixture()
        fixture.use {
            val first = fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.RECONCILE,
                71L,
            )
            val second = fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.RECONCILE,
                71L,
            )

            assertEquals(BleReconnectOwnerDisposition.REPAIRED, first.ownerDisposition)
            assertEquals(BleReconnectOwnerDisposition.REUSED, second.ownerDisposition)
            assertEquals(1, fixture.createdGatts.size)
            assertSame(fixture.createdGatts.single(), fixture.targetCache().myGatt)
        }
    }

    @Test
    fun `reconcile replaces orphan gatt once and leaves peer endpoint untouched`() {
        val fixture = Fixture()
        fixture.use {
            val peerGatt = Mockito.mock(BluetoothGatt::class.java)
            val peer = fixture.device(
                uuid = "AA:BB:CC:DD:EE:02",
                name = "Even G2_R_peer",
                state = BleConnectState.CONNECTED,
            ).also { it.update(peerGatt) }
            fixture.devices += peer

            fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.RECONCILE,
                81L,
            )
            val orphan = fixture.createdGatts.single()
            fixture.ownerHealth = BlePendingOwnerHealth.STALE

            val repaired = fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.RECONCILE,
                81L,
            )

            assertEquals(BleReconnectOwnerDisposition.REPAIRED, repaired.ownerDisposition)
            assertEquals(listOf(orphan), fixture.invalidatedGatts)
            assertEquals(2, fixture.createdGatts.size)
            assertSame(fixture.createdGatts.last(), fixture.targetCache().myGatt)
            assertSame(peerGatt, peer.myGatt)
            Mockito.verifyNoInteractions(peerGatt)
        }
    }

    @Test
    fun `higher session tears down only the exact target and creates one replacement`() {
        val fixture = Fixture()
        fixture.use {
            fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.INITIAL,
                91L,
            )
            val oldGatt = fixture.createdGatts.single()

            val rebound = fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.RECONCILE,
                92L,
            )

            assertEquals(BleReconnectOwnerDisposition.REPAIRED, rebound.ownerDisposition)
            assertEquals(92L, rebound.sessionGeneration)
            assertEquals(listOf(oldGatt), fixture.sessionReboundGatts)
            assertEquals(2, fixture.createdGatts.size)
        }
    }

    private class Fixture : AutoCloseable {
        val config = BleConfig.empty().copy(name = "g2-test", autoReconnect = true)
        val devices = mutableListOf<BleDevice>()
        val target = device("AA:BB:CC:DD:EE:01", "Even G2_L_test")
        val createdGatts = mutableListOf<BluetoothGatt>()
        val invalidatedGatts = mutableListOf<BluetoothGatt>()
        val sessionReboundGatts = mutableListOf<BluetoothGatt>()
        var ownerHealth = BlePendingOwnerHealth.PRE_PHYSICAL

        private val adapter = Mockito.mock(BluetoothAdapter::class.java)
        private val remoteDevice = Mockito.mock(BluetoothDevice::class.java)
        private val elapsedRealtime = Mockito.mockStatic(SystemClock::class.java)
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

        val supervisor: BleAutoReconnectSupervisor

        init {
            Mockito.`when`(remoteDevice.name).thenReturn(target.name)
            Mockito.`when`(remoteDevice.address).thenReturn(target.uuid)
            Mockito.`when`(adapter.getRemoteDevice(target.uuid)).thenReturn(remoteDevice)
            elapsedRealtime.`when`<Long> { SystemClock.elapsedRealtime() }.thenReturn(1_000L)

            val factory = BlePassiveGattFactory { _, _, _, _ ->
                Mockito.mock(BluetoothGatt::class.java).also(createdGatts::add)
            }
            supervisor = BleAutoReconnectSupervisor(
                connectedDevices = devices,
                bleConfigs = { listOf(config) },
                bluetoothAdapter = { adapter },
                context = { null },
                mainScope = { scope },
                bleState = { 5 },
                isBluetoothEnabled = { true },
                isUpgradeDevice = { false },
                createConnectCallback = { _, _, _ ->
                    Mockito.mock(BleGattSessionCallback::class.java)
                },
                promotePendingAdmission = {},
                persistReconnectTarget = {},
                handleConnectState = { _, _, _ -> },
                sendLog = { _, _ -> },
                classifyPendingPassiveGattOwner = { _, _ -> ownerHealth },
                invalidatePendingPassiveGatt = { _, gatt ->
                    invalidatedGatts += gatt
                    BlePendingOwnerDisposition.REPAIRED_STALE_OWNER
                },
                invalidatePassiveGattForSessionRebind = { _, gatt ->
                    sessionReboundGatts += gatt
                    true
                },
                passiveGattFactory = factory,
                visibleDirectGattFactory = factory,
                attemptScheduler = BleReconnectAttemptScheduler { _, _ ->
                    BleReconnectScheduleHandle {}
                },
            )
        }

        fun device(
            uuid: String,
            name: String,
            state: BleConnectState = BleConnectState.NONE,
        ) = BleDevice(config, name, uuid, "sn-$uuid", 0, state)

        fun targetCache(): BleDevice = devices.single { it.uuid == target.uuid }

        override fun close() {
            elapsedRealtime.close()
        }
    }
}

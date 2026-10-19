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
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.mockito.Mockito

/**
 * Supervisor 仍引用已被 Manager 回收的孤儿 GATT 时的回连收敛。
 *
 * 断连调度与对账/手动激活并发会让 stale 修复回收 Supervisor 新建的 GATT；这里注入
 * Manager 边界复现该交错，验证 deadline 仍会回收重建，更高 session 也能完成换绑。
 */
class BleAutoReconnectSupervisorOrphanOwnerTest {
    @Test
    fun `skipped attempt keeps the orphan gatt deadline so native reconnect rebuilds it`() {
        val fixture = Fixture()
        fixture.use {
            fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.INITIAL,
                35L,
            )
            val businessGatt = fixture.createdGatts.single()
            // 业务 connected：物理 deadline 已撤销，attempt 归零，下一次系统断连立即重建。
            assertTrue(fixture.supervisor.onPassivePhysicalConnected(fixture.target.uuid, businessGatt))
            fixture.supervisor.arm(
                fixture.device(fixture.target.uuid, fixture.target.name, BleConnectState.CONNECTED),
            )
            // 对账已读到旧 owner 并等待 Manager 锁；断连回调先完成调度并建立新 GATT，
            // 随后 Manager 的 stale 修复回收了这条 Supervisor 仍引用的新 GATT。
            fixture.ownerHealth = BlePendingOwnerHealth.STALE
            fixture.onClassify = {
                fixture.onClassify = null
                fixture.supervisor.schedule(
                    fixture.target.uuid,
                    BleConnectState.DISCONNECT_FROM_SYS,
                    terminalGattToDetach = businessGatt,
                )
            }

            fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.RECONCILE,
                35L,
            )

            assertEquals(2, fixture.createdGatts.size)
            val orphanGatt = fixture.createdGatts.last()
            val orphanDeadline = fixture.scheduled.last()
            assertEquals(15_000L, orphanDeadline.delayMs)
            assertFalse(orphanDeadline.cancelled, "skipped attempt must keep the orphan GATT deadline")

            orphanDeadline.fire()
            val rebuild = fixture.scheduled.last()
            assertEquals(1_500L, rebuild.delayMs)
            rebuild.fire()

            assertEquals(listOf(businessGatt, orphanGatt), fixture.invalidatedGatts)
            assertEquals(3, fixture.createdGatts.size)
            assertTrue(fixture.supervisor.ownerSnapshot(fixture.target.uuid)?.hasPassiveGatt == true)
        }
    }

    @Test
    fun `higher session repairs a stale orphan owner before installing the session`() {
        val fixture = Fixture()
        fixture.use {
            fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.INITIAL,
                35L,
            )
            val orphanGatt = fixture.createdGatts.single()
            // Manager 已不持有该 GATT：exact 换绑拒绝，健康分类为 STALE。
            fixture.sessionRebindAccepted = false
            fixture.ownerHealth = BlePendingOwnerHealth.STALE

            val manual = fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.MANUAL_RECONNECT,
                BleReconnectActivationMode.PROMOTION,
                50L,
            )

            assertEquals(BleReconnectOwnerDisposition.REPAIRED, manual.ownerDisposition)
            assertEquals("sessionRebound", manual.reason)
            assertEquals(50L, manual.sessionGeneration)
            assertEquals(listOf(orphanGatt), fixture.invalidatedGatts)
            assertEquals(2, fixture.createdGatts.size)
            assertEquals(50L, fixture.callbackSessions.last())
        }
    }

    @Test
    fun `higher session still rejects when the refused owner is already admitted`() {
        val fixture = Fixture()
        fixture.use {
            fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.AUTO_RECONNECT,
                BleReconnectActivationMode.INITIAL,
                35L,
            )
            fixture.sessionRebindAccepted = false
            fixture.ownerHealth = BlePendingOwnerHealth.ADMITTED

            val manual = fixture.supervisor.activate(
                fixture.target,
                BleConnectSource.MANUAL_RECONNECT,
                BleReconnectActivationMode.PROMOTION,
                50L,
            )

            assertEquals(BleReconnectOwnerDisposition.REJECTED, manual.ownerDisposition)
            assertEquals("sessionNotInstalled", manual.reason)
            assertEquals(35L, manual.sessionGeneration)
            assertTrue(fixture.invalidatedGatts.isEmpty())
            assertEquals(1, fixture.createdGatts.size)
        }
    }

    /** 记录 scheduler 提交的 deadline/retry，测试可检查是否被撤销并手动触发。 */
    private class ScheduledAttempt(val delayMs: Long, private val attempt: () -> Unit) {
        var cancelled = false

        fun fire() = attempt()
    }

    private class Fixture : AutoCloseable {
        val config = BleConfig.empty().copy(name = "r1-test", autoReconnect = true)
        val devices = mutableListOf<BleDevice>()
        val target = device("ring-endpoint", "ring-test")
        val createdGatts = mutableListOf<BluetoothGatt>()
        val invalidatedGatts = mutableListOf<BluetoothGatt>()
        val callbackSessions = mutableListOf<Long>()
        val scheduled = mutableListOf<ScheduledAttempt>()
        var ownerHealth = BlePendingOwnerHealth.PRE_PHYSICAL
        var sessionRebindAccepted = true
        /** 模拟健康分类等待 Manager 锁期间，断连回调线程先完成的状态推进。 */
        var onClassify: (() -> Unit)? = null

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
                createConnectCallback = { _, _, session ->
                    callbackSessions += session
                    Mockito.mock(BleGattSessionCallback::class.java)
                },
                promotePendingAdmission = {},
                persistReconnectTarget = {},
                handleConnectState = { _, _, _ -> },
                sendLog = { _, _ -> },
                classifyPendingPassiveGattOwner = { _, _ ->
                    onClassify?.invoke()
                    ownerHealth
                },
                invalidatePendingPassiveGatt = { _, gatt ->
                    invalidatedGatts += gatt
                    BlePendingOwnerDisposition.REPAIRED_STALE_OWNER
                },
                invalidatePassiveGattForSessionRebind = { _, _, _, _ -> sessionRebindAccepted },
                passiveGattFactory = factory,
                visibleDirectGattFactory = factory,
                attemptScheduler = BleReconnectAttemptScheduler { delayMs, attempt ->
                    val entry = ScheduledAttempt(delayMs, attempt)
                    scheduled += entry
                    BleReconnectScheduleHandle { entry.cancelled = true }
                },
            )
        }

        fun device(
            uuid: String,
            name: String,
            state: BleConnectState = BleConnectState.NONE,
        ) = BleDevice(config, name, uuid, "pair-test", 0, state)

        override fun close() {
            elapsedRealtime.close()
        }
    }
}

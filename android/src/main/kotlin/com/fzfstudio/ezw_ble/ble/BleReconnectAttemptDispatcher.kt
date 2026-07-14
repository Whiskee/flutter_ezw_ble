package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.content.Context
import android.os.Build
import java.util.Timer
import java.util.TimerTask

/** 可取消的重连延迟任务；监督器只依赖 cancel，不依赖具体 Timer 实现。 */
internal fun interface BleReconnectScheduleHandle {
    fun cancel()
}

/**
 * 延迟重连调度器。
 *
 * 注入该边界可以在行为测试中证明首轮 activation 没有偷偷进入异步 Timer，后续失败重试
 * 仍可使用真实 Timer + manager 主线程分发。
 */
internal fun interface BleReconnectAttemptScheduler {
    fun schedule(delayMs: Long, attempt: () -> Unit): BleReconnectScheduleHandle
}

/** 真正创建 Android passive `connectGatt(true)` 的可注入工厂。 */
internal fun interface BlePassiveGattFactory {
    fun connect(
        device: BluetoothDevice,
        context: Context?,
        callback: BleGattSessionCallback,
    ): BluetoothGatt?
}

/** 生产环境 GATT 工厂；所有回连路径固定使用 autoConnect=true。 */
internal object AndroidBlePassiveGattFactory : BlePassiveGattFactory {
    override fun connect(
        device: BluetoothDevice,
        context: Context?,
        callback: BleGattSessionCallback,
    ): BluetoothGatt? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        device.connectGatt(
            context,
            true,
            callback,
            BluetoothDevice.TRANSPORT_LE,
            BluetoothDevice.PHY_LE_2M,
        )
    } else {
        device.connectGatt(context, true, callback)
    }
}

/** 使用 Timer 承载非首轮防抖，并把实际 attempt 交回 manager 指定线程。 */
internal class TimerBleReconnectAttemptScheduler(
    private val dispatch: (() -> Unit) -> Unit,
) : BleReconnectAttemptScheduler {
    override fun schedule(delayMs: Long, attempt: () -> Unit): BleReconnectScheduleHandle {
        val timer = Timer()
        timer.schedule(object : TimerTask() {
            override fun run() {
                dispatch(attempt)
            }
        }, delayMs)
        return BleReconnectScheduleHandle { timer.cancel() }
    }
}

/**
 * 首轮/重试分发策略。
 *
 * `delayMs == 0` 必须同步调用 GATT starter；这是 MethodChannel success 前所有目标都已创建
 * pending GATT 的硬契约。只有大于 0 的失败重试才允许进入 scheduler。
 */
internal class BleReconnectAttemptDispatcher(
    private val scheduler: BleReconnectAttemptScheduler,
    private val gattStarter: (String, Long?) -> Unit,
) {
    fun dispatch(
        uuid: String,
        delayMs: Long,
        scheduleGeneration: Long? = null,
    ): BleReconnectScheduleHandle? {
        if (delayMs <= 0L) {
            gattStarter(uuid, scheduleGeneration)
            return null
        }
        return scheduler.schedule(delayMs) { gattStarter(uuid, scheduleGeneration) }
    }
}

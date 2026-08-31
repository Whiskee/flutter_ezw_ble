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
        highReliabilityMode: Boolean,
    ): BluetoothGatt?
}

/**
 * 三条 Android GATT 创建路径的唯一 PHY 选择入口。
 *
 * `autoConnect=true` 时 Android 官方说明 connectGatt 的 phy 参数不生效，但仍传入同一策略值
 * 维持代码一致；真实 passive 链路会在 STATE_CONNECTED 后由 callback 再请求目标 PHY。
 */
internal object AndroidBleGattConnector {
    fun connect(
        device: BluetoothDevice,
        context: Context?,
        autoConnect: Boolean,
        callback: BleGattSessionCallback,
        highReliabilityMode: Boolean,
    ): BluetoothGatt? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        device.connectGatt(
            context,
            autoConnect,
            callback,
            BluetoothDevice.TRANSPORT_LE,
            AndroidBleAdaptiveLinkPolicy.initialConnectPhyMask(highReliabilityMode),
        )
    } else {
        device.connectGatt(context, autoConnect, callback)
    }
}

/** 生产环境长期回连 GATT 工厂；常态保持 `autoConnect=true` 的系统 pending 请求。 */
internal object AndroidBlePassiveGattFactory : BlePassiveGattFactory {
    override fun connect(
        device: BluetoothDevice,
        context: Context?,
        callback: BleGattSessionCallback,
        highReliabilityMode: Boolean,
    ): BluetoothGatt? = AndroidBleGattConnector.connect(
        device = device,
        context = context,
        autoConnect = true,
        callback = callback,
        highReliabilityMode = highReliabilityMode,
    )
}

/**
 * 目标已被辅助扫描确认可见时使用的一次性真实直连。
 *
 * 它只由 supervisor 的单槽队列调度，不能替代长期 passive owner；成功或终态后仍由
 * 原有 autoReconnect 任务继续维持后续回连意图。
 */
internal object AndroidBleVisibleDirectGattFactory : BlePassiveGattFactory {
    override fun connect(
        device: BluetoothDevice,
        context: Context?,
        callback: BleGattSessionCallback,
        highReliabilityMode: Boolean,
    ): BluetoothGatt? = AndroidBleGattConnector.connect(
        device = device,
        context = context,
        autoConnect = false,
        callback = callback,
        highReliabilityMode = highReliabilityMode,
    )
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
        // 1、首轮 activation 必须同步创建 passive GATT，保证所有目标在 native 返回前已入系统。
        if (delayMs <= 0L) {
            gattStarter(uuid, scheduleGeneration)
            return null
        }
        // 2、失败重试才进入可取消 scheduler；回调仍携带 generation 供 supervisor 校验。
        return scheduler.schedule(delayMs) { gattStarter(uuid, scheduleGeneration) }
    }
}

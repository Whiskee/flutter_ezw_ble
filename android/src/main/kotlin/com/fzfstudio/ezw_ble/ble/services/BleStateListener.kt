package com.fzfstudio.ezw_ble.ble.services

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build

class BleStateListener(private val context: Context) {

    // 定义回调接口
    interface BluetoothStateCallback {
        fun onBluetoothStateChanged(state: Int)
        /** 透传权威 bond 前后状态；上层必须结合 exact session 决定是否推进连接。 */
        fun onDeviceBondStateChanged(device: BluetoothDevice, bondState: Int, previousBondState: Int) {}
        //  可选
        fun onDeviceConnected(device: BluetoothDevice) {}
        //  可选
        fun onDeviceDisconnected(device: BluetoothDevice) {}
    }

    private var callback: BluetoothStateCallback? = null

    /**
     * `unregisterReceiver` 会在 receiver 未注册时抛出 IllegalArgumentException。
     * FlutterEngine 的 detach/recreate 可能让 release 进入不止一次，因此必须由
     * listener 自己保存注册事实，而不能仅依赖外层对象是否已初始化。
     */
    private var isReceiverRegistered = false

    // 定义广播接收器
    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            //  获取监听到的设备对象
            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                intent?.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
            when (intent?.action) {
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                    callback?.onBluetoothStateChanged(state)
                }
                BluetoothDevice.ACTION_ACL_CONNECTED -> {
                    device?.let { callback?.onDeviceConnected(it) }
                }
                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                    // 1、BOND_BONDING 也是状态机证据，不能再压缩成 isBonded 或提前丢弃。
                    val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)
                    val previousBondState = intent.getIntExtra(
                        BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE,
                        -1,
                    )
                    // 2、Manager 使用 current/previous 识别成功与明确的 BONDING -> NONE 拒绝。
                    device?.let {
                        callback?.onDeviceBondStateChanged(it, bondState, previousBondState)
                    }
                }
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                    device?.let { callback?.onDeviceDisconnected(it) }
                }
            }
        }
    }

    /**
     * 注册监听
     */
    @Synchronized
    fun register(callback: BluetoothStateCallback) {
        this.callback = callback
        // 同一 listener 已登记时只刷新业务回调，不能重复向 Context 登记同一个 receiver。
        if (isReceiverRegistered) return

        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED) // 监听蓝牙状态变化
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED) // 监听设备连接
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED) // 监听设备配对状态
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED) // 监听设备断开
        }
        context.registerReceiver(bluetoothReceiver, filter)
        isReceiverRegistered = true
    }

    /**
     * 幂等释放 receiver。
     *
     * 先检查本 listener 的登记状态；同时兜住系统已提前移除 receiver 的极端生命周期，
     * 防止 plugin detach 阶段的清理异常升级为 Activity.onDestroy 崩溃。
     */
    @Synchronized
    fun unregister() {
        if (!isReceiverRegistered) return

        try {
            context.unregisterReceiver(bluetoothReceiver)
        } catch (_: IllegalArgumentException) {
            // Context 已不再持有 receiver；本次释放的目标已达成。
        } finally {
            isReceiverRegistered = false
            callback = null
        }
    }
}

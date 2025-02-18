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
        //  可选
        fun onDeviceBondStateChanged(device: BluetoothDevice, isBonded: Boolean) {}
        //  可选
        fun onDeviceConnected(device: BluetoothDevice) {}
        //  可选
        fun onDeviceDisconnected(device: BluetoothDevice) {}
    }

    private var callback: BluetoothStateCallback? = null

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
                    val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)
                    //  避免多次回调
                    if (bondState == BluetoothDevice.BOND_BONDING) {
                        return
                    }
                    device?.let { callback?.onDeviceBondStateChanged(it, bondState == BluetoothDevice.BOND_BONDED) }
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
    fun register(callback: BluetoothStateCallback) {
        this.callback = callback
        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED) // 监听蓝牙状态变化
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED) // 监听设备连接
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED) // 监听设备配对状态
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED) // 监听设备断开
        }
        context.registerReceiver(bluetoothReceiver, filter)
    }

    // 注销监听
    fun unregister() = context.unregisterReceiver(bluetoothReceiver)
}

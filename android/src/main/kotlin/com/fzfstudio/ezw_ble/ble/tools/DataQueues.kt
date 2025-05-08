package com.fzfstudio.ezw_ble.ble.tools

import com.fzfstudio.ezw_ble.ble.models.BleCmd
import com.fzfstudio.ezw_ble.ble.models.enums.BleUuidType



class DataQueues private constructor() {
    companion object {
        val instance = DataQueues()
    }
    /// 数据队列
    private val queues: MutableMap<String, MutableList<BleCmd>> = mutableMapOf()

    /**
     * 添加数据到队列
     */
    fun addToQueues(cmdData: BleCmd) {
        if (queues[cmdData.uuid] == null) {
            queues[cmdData.uuid] = mutableListOf()
        }
        queues[cmdData.uuid]?.add(cmdData)
    }

    /**
     * 弹出队列数据
     */
    fun popQueues(device: String) {
        val queue = queues[device]
        if (queue == null || queue.isEmpty()) {
            return
        }
        queue.removeAt(0)
    }

    /**
     * 获取第一个数据
     */
    fun getFirstCmd(device: String): BleCmd? = queues[device]?.firstOrNull()

    /**
     * 获取队列数据大小
     */
    fun getQueuesSize(device: String): Int = queues[device]?.size ?: 0

    /**
     * 清空队列
     */
    fun clearQueues() = queues.clear()
}
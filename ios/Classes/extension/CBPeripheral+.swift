//
//  CBPeripheral+.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/3.
//

import CoreBluetooth

extension CBPeripheral {
    
    /**
     * 转化可识别蓝牙数据。
     *
     * CoreBluetooth 的 `peripheral.name` 不一定在首次扫描时就有值；部分设备只把名称放在
     * advertisement local name 中。因此扫描链路可以传入 `advertisedName`，避免搜索结果
     * 因系统对象名为空而展示为空名或被上层误判。
     */
    func toBleDevice(
        belongConfig: String,
        sn: String,
        rssi: Int,
        mac: String = "",
        advertisedName: String? = nil
    ) -> BleDevice {
        // 1. 优先使用广播 local name，fallback 到 CoreBluetooth 缓存名。
        let resolvedName = advertisedName?.isEmpty == false ? advertisedName! : (name ?? "")
        return BleDevice(
            belongConfig: belongConfig,
            name: resolvedName,
            uuid: identifier.uuidString,
            sn: sn,
            mac: mac,
            rssi: rssi,
        )
    }
    
}

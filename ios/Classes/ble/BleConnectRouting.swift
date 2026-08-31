//
//  BleConnectRouting.swift
//  flutter_ezw_ble
//
//  Centralizes connect request log context so foreground connect, reconnect,
//  and reconnect paths can use a stable, grep-friendly log shape.
//

import Foundation

/**
 *  连接请求日志上下文。
 *
 *  这里不承载连接决策，只负责把关键路由输入整理成稳定日志，避免各入口各写一套自然语言日志。
 */
struct BleConnectRequestLogContext {
    /// 原生连接目标 UUID，可能来自扫描结果、持久化目标或进程内已知 peripheral。
    let uuid: String
    /// 原生连接目标名称，用于 UUID 缺失或临时 UUID 阶段的辅助匹配。
    let name: String
    /// Dart 注入的 BLE 配置名，用于定位私有服务规则。
    let configName: String
    /// 是否要求直接连接；auto reconnect 通常会走 direct path。
    let directConnect: Bool
    /// 是否 OTA 后恢复连接，日志保留该字段方便排查升级链路。
    let afterUpgrade: Bool
    /// 当前进行中的连接请求数，用于排查 stale callback 和并发请求。
    let activeRequests: Int
    /// 已缓存的连接设备数，用于判断是否命中 known peripheral。
    let connectedDevices: Int
    /// 扫描缓存数，用于判断是否依赖 scan result 路由。
    let scanCache: Int

    /**
     *  输出固定 connect/request 日志。
     *
     *  日志字段保持稳定，方便终端和 QA 脚本直接 grep 阶段与关键身份字段。
     */
    var message: String {
        "connect/request uuid=\(uuid) name=\(name), config=\(configName), directConnect=\(directConnect), afterUpgrade=\(afterUpgrade), activeRequests=\(activeRequests), connectedDevices=\(connectedDevices), scanCache=\(scanCache)"
    }
}

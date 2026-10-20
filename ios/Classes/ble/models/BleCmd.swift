//
//  BleCmd.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/4.
//

import Foundation

struct BleCmd: Codable {
    //  设备唯一识别码
    var uuid: String
    //  私有服务类型
    var psType: Int
    //  待传输数据
    var data: Data?
    //  是否成功
    var isSuccess: Bool = true
    //  OTA recovery / 已确认common业务owner的session；0表示初始化或未知。
    var sessionGeneration: Int64 = 0
    //  Native物理attempt；common只在当前对象与已确认业务owner匹配时附带。
    var attemptGeneration: Int64 = 0
    //  G2 OTA transaction identity. Empty/0 表示旧事件或非 OTA；Dart 必须 fail closed。
    var otaTransactionId: String = ""
    var otaGeneration: Int64 = 0
    var otaInstanceId: String = ""
    //  当前 notify callback 冻结的原生接收身份；不能从外层 legacy/OTA pair 推导。
    var receiveIdentity: BleReceiveIdentity?
    
    func toMap() -> [String:Any] {
        var jsonMap: [String:Any] = [
            "uuid": uuid,
            "psType": psType,
            "isSuccess": isSuccess,
            "sessionGeneration": sessionGeneration,
            "attemptGeneration": attemptGeneration,
            "otaTransactionId": otaTransactionId,
            "otaGeneration": otaGeneration,
            "otaInstanceId": otaInstanceId
        ]
        if let data = data {
            jsonMap["data"] = data.base64EncodedString()
        }
        if let receiveIdentity = receiveIdentity {
            jsonMap["receiveIdentity"] = receiveIdentity.toMap()
        }
        return jsonMap
    }
}

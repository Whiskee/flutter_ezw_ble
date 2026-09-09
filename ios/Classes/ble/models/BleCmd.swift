//
//  BleCmd.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/4.
//

struct BleCmd: Codable {
    //  设备唯一识别码
    var uuid: String
    //  私有服务类型
    var psType: Int
    //  待传输数据
    var data: Data?
    //  是否成功
    var isSuccess: Bool = true
    //  OTA recovery batch 业务 session；0 表示旧事件或非 OTA。
    var sessionGeneration: Int64 = 0
    //  Native 物理连接 attempt；0 表示旧事件或非 OTA。
    var attemptGeneration: Int64 = 0
    //  G2 OTA transaction identity. Empty/0 表示旧事件或非 OTA；Dart 必须 fail closed。
    var otaTransactionId: String = ""
    var otaGeneration: Int64 = 0
    var otaInstanceId: String = ""
    
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
        return jsonMap
    }
}

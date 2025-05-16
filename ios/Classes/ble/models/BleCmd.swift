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
    
    func toMap() -> [String:Any] {
        var jsonMap: [String:Any] = [
            "uuid": uuid,
            "psType": psType,
            "isSuccess": isSuccess
        ]
        if let data = data {
            jsonMap["data"] = data.base64EncodedString()
        }
        return jsonMap
    }
}

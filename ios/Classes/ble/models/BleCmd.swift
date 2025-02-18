//
//  BleCmd.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/4.
//

struct BleCmd: Codable {
    var uuid: String
    var data: Data?
    var isSuccess: Bool = true
    
    func toMap() -> [String:Any] {
        var jsonMap: [String:Any] = [
            "uuid":uuid,
            "isSuccess":isSuccess
        ]
        if let data = data {
            jsonMap["data"] = data.base64EncodedString()
        }
        return jsonMap
    }
}

//
//  BleSnRule.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/9.
//

struct BleSnRule: Codable {
    let byteLength: Int
    let startSubIndex: Int
    let replaceRex: String
    let scanFilterMarks: [String]
    let isMatchBySn: Bool
    let matchCount: Int
    
    static func empty() -> BleSnRule {
        return BleSnRule(byteLength: 0, startSubIndex: 0, replaceRex: "", scanFilterMarks: [], isMatchBySn: false, matchCount: 0)
    }
}

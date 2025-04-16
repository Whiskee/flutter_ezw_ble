//
//  BleSnRule.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/9.
//

struct BleSnRule: Codable {
    //  总长度识别，如果为0，则表示适配所有长度
    let byteLength: Int
    //  开始截断位置
    let startSubIndex: Int
    //  自定义正则修正字符
    let replaceRex: String
    //  扫描设备时，只返回SN含有过滤标识的对象
    let scanFilterMarks: [String]
    //  组合设备数:总数，如果为1不执行匹配，返回单个设备，如果大于2则默认开启匹配模式
    let matchCount: Int
    
    static func empty() -> BleSnRule {
        return BleSnRule(byteLength: 0, startSubIndex: 0, replaceRex: "", scanFilterMarks: [], matchCount: 0)
    }
}

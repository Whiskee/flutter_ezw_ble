extension MacEndianExtension on String {
  /// 检查当前字符串是否是小端序的蓝牙 MAC 地址。
  /// 如果已经是小端序，返回原字符串；
  /// 如果是大端序，则转换为小端序后返回。
  String toLittleEndianMac() {
    //  1. 提取 MAC 地址中的字节部分
    final regex = RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$');
    if (!regex.hasMatch(this)) {
      return "";
    }
    //  2. 分割为字节数组
    final parts = split(':');
    //  3. 检查是否已经是小端序（简单启发式判断）
    //  - 一般小端序的倒序后与正常厂商地址(OUI)不匹配，比如前3字节不是常见厂商段。
    //  - 这里假定以 "C4:85:08"、"A4:C1:38" 这类前缀的是大端序。
    //  - 当然，如果你能通过厂商 OUI 表精确判断，可以在此扩展。
    bool isLittleEndian = false;
    // 检测是否明显为小端（例如字节顺序不常见）
    final firstByte = parts.first.toUpperCase();
    final lastByte = parts.last.toUpperCase();
    if (int.tryParse(firstByte, radix: 16)! <
        int.tryParse(lastByte, radix: 16)!) {
      isLittleEndian = true;
    }
    // 4. 返回：
    //  - 如果已经是小端，直接返回
    //  - 否则反转字节顺序，返回小端序
    return isLittleEndian
        ? toUpperCase()
        : parts.reversed.join(':').toUpperCase();
  }

  /// 将MAC地址反转
  String reverseMac() {
    final parts = split(':');
    final reversedParts = parts.reversed.join(':');
    return reversedParts;
  }
}

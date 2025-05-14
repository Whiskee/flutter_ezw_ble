package com.fzfstudio.ezw_ble.ble.tools

import java.security.MessageDigest

object MessageDigestTool {
    /**
     * 使用 MD5 哈希算法生成哈希值
     *
     * @param input 输入字符串
     * @return 哈希值的整数表示
     */
    fun md5Hash(input: String): Int {
        val md = MessageDigest.getInstance("MD5")
        val hashBytes = md.digest(input.toByteArray())
        return hashBytes.fold(0) { acc, byte -> acc * 31 + byte.toInt() }
    }
}
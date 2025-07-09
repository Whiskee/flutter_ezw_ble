enum class BleLoggerTag {
    //  信息
    d,
    //  错误
    e;

    //  获取标识
    val tag: String
        get() = when (this) {
            d -> "[d]-"
            e -> "[e]-"
        }
}
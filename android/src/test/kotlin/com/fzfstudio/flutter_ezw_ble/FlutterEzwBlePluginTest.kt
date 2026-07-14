package com.fzfstudio.flutter_ezw_ble

import android.content.Context
import com.fzfstudio.ezw_ble.FlutterEzwBlePlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.test.Test
import org.mockito.Mockito

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class FlutterEzwBlePluginTest {
  @Test
  fun onMethodCall_getPlatformVersion_returnsExpectedValue() {
    val plugin = FlutterEzwBlePlugin()

    // 单元测试没有 FlutterEngine attach 生命周期；只补齐分发入口要求的 application context。
    FlutterEzwBlePlugin::class.java.getDeclaredField("context").apply {
      isAccessible = true
      set(plugin, Mockito.mock(Context::class.java))
    }

    val call = MethodCall("getPlatformVersion", null)
    val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(call, mockResult)

    Mockito.verify(mockResult).success("Android " + android.os.Build.VERSION.RELEASE)
  }
}

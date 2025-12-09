package com.fzfstudio.ezw_ble

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import com.fzfstudio.ezw_ble.ble.BleEC
import com.fzfstudio.ezw_ble.ble.BleMC
import com.fzfstudio.ezw_ble.ble.BleManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/// 全局参数
/// - 函数频道名称
const val EZW_BLE_CHANNEL_NAME: String = "flutter_ezw_ble"

/** EvenConnectPlugin */
class FlutterEzwBlePlugin: FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel

  private lateinit var context: Context

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    //  MethodChannel
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, EZW_BLE_CHANNEL_NAME)
    channel.setMethodCallHandler(this)
    //  EvenChannel
    BleEC.entries.forEach { it.registerEventChannel(flutterPluginBinding.binaryMessenger) }
    //  初始化蓝牙工具
    BleManager.instance.init(flutterPluginBinding.applicationContext)
    //  获取Application并执行监听生命周期
    val application: Application = flutterPluginBinding.applicationContext as Application
    application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
      override fun onActivityCreated(activity: Activity,savedInstanceState: Bundle?) {}
      override fun onActivityStarted(activity: Activity) = BleManager.instance.checkBluetoothPermission()
      override fun onActivityStopped(activity: Activity) {}
      override fun onActivityResumed(activity: Activity) {}
      override fun onActivityPaused(activity: Activity) {}
      override fun onActivitySaveInstanceState(activity: Activity,outState: Bundle) {}
      override fun onActivityDestroyed(activity: Activity) {}
    })
  }

  /**
   * MARK - Interface MethodCallHandler
   */
  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) = BleMC.from(call.method).handle(context, call.arguments, result)

  /**
   * MARK - Interface MethodCallHandler
   */
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
      channel.setMethodCallHandler(null)
      BleManager.instance.release()
  }

}

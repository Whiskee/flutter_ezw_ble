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

/** Flutter MethodChannel 与 EventChannel 的基础 channel name。 */
const val EZW_BLE_CHANNEL_NAME: String = "flutter_ezw_ble"

/**
 * Flutter 插件入口。
 *
 * 该类只负责 FlutterEngine 生命周期、MethodChannel 绑定、EventChannel 注册和 Activity 生命周期桥接。
 * BLE 扫描、连接、GATT、自动回连等业务逻辑必须保留在 `BleManager` 及其协作类中。
 */
class FlutterEzwBlePlugin : FlutterPlugin, MethodCallHandler {
  /**
   * Flutter 与 Android 原生通信使用的 MethodChannel。
   *
   * 引擎 detach 时必须清空 handler，避免旧 engine 销毁后仍有方法调用落到失效插件实例。
   */
  private lateinit var channel: MethodChannel

  /** Application context，用于打开设置页和转发 MethodChannel 调用。 */
  private lateinit var context: Context

  /**
   * 保存已注册 Activity 生命周期回调所属的 Application。
   *
   * Flutter hot restart / engine detach 时必须用同一个 Application 反注册 callback，
   * 否则旧插件实例释放后仍会收到 Activity started 事件并触发权限刷新。
   */
  private var lifecycleApplication: Application? = null

  /**
   * 保存 Activity 生命周期回调实例。
   *
   * Android 反注册要求传入注册时的同一个对象；匿名对象如果不保存引用，会在
   * onDetachedFromEngine 后永久留在 Application callbacks 列表里。
   */
  private var activityLifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null

  /**
   * FlutterEngine 绑定插件时调用。
   *
   * 绑定流程包括：缓存 context、注册 MethodChannel、注册所有 EventChannel、初始化 BleManager，
   * 并监听 Activity start 事件以刷新 Android 蓝牙权限状态。
   */
  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    // 1. 缓存 applicationContext，避免持有 Activity context 造成生命周期泄漏。
    context = flutterPluginBinding.applicationContext

    // 2. 注册 MethodChannel，所有 Dart 方法都会转发到 BleMC 分发器。
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, EZW_BLE_CHANNEL_NAME)
    channel.setMethodCallHandler(this)

    // 3. 每个 BleEC 对应一个独立 EventChannel，事件 sink 由 BleChannel 内部维护。
    BleEC.entries.forEach { it.registerEventChannel(flutterPluginBinding.binaryMessenger) }

    // 4. 初始化 BLE manager，建立 Android BluetoothAdapter/Manager 依赖。
    BleManager.instance.init(flutterPluginBinding.applicationContext)

    // 5. Activity 启动时刷新权限状态；权限申请本身交给 Dart 侧三方工具实现。
    val application: Application = flutterPluginBinding.applicationContext as Application
    unregisterActivityLifecycleCallbacks()
    val callbacks = object : Application.ActivityLifecycleCallbacks {
      /** Activity 创建时无需处理 BLE 状态。 */
      override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

      /** Activity 可见时刷新实时蓝牙权限与开关状态。 */
      override fun onActivityStarted(activity: Activity) {
        runCatching { BleManager.instance.refreshBleState("activityStarted") }
      }

      /** Activity 停止时不主动断开 BLE，避免后台连接被生命周期误杀。 */
      override fun onActivityStopped(activity: Activity) {}

      /** 权限弹窗返回通常只触发 resumed，必须在此处立即刷新，不能等待下一次 started。 */
      override fun onActivityResumed(activity: Activity) {
        runCatching { BleManager.instance.refreshBleState("activityResumed") }
      }

      /** Activity paused 时不主动断开 BLE，后台业务由连接状态机处理。 */
      override fun onActivityPaused(activity: Activity) {}

      /** 保存实例状态不需要写入 BLE 运行态，连接状态由原生缓存和 Dart 事件同步。 */
      override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

      /** Activity 销毁不代表 FlutterEngine 销毁，因此不在这里 release BleManager。 */
      override fun onActivityDestroyed(activity: Activity) {}
    }
    lifecycleApplication = application
    activityLifecycleCallbacks = callbacks
    application.registerActivityLifecycleCallbacks(callbacks)
  }

  /**
   * 处理 Flutter MethodChannel 调用。
   *
   * 该方法只做枚举转换和分发，具体参数解析与原生调用在 `BleMC.handle` 中完成。
   */
  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    // 1. Dart 方法名统一转成 BleMC 枚举，未知方法会落到 UNKNOWN 并返回 null。
    BleMC.from(call.method).handle(context, call.arguments, result)
  }

  /**
   * FlutterEngine 解绑插件时调用。
   *
   * 这里释放 MethodChannel handler，并通知 BleManager 停止扫描、释放连接和取消协程。
   */
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // 1. 清空 handler，避免 engine 释放后仍收到 Dart 方法调用。
    channel.setMethodCallHandler(null)

    // 2. 反注册 Activity 生命周期回调，避免 hot restart / engine 重建后重复刷新权限。
    unregisterActivityLifecycleCallbacks()

    // 3. 释放 BLE manager 持有的扫描、GATT、监听器和协程资源。
    BleManager.instance.release()
  }

  /**
   * 反注册 Activity 生命周期回调。
   *
   * 该方法允许重复调用：没有已注册 callback 时直接返回；有 callback 时先反注册，
   * 再清空引用，保证下一次 onAttachedToEngine 可以注册全新的 engine 绑定。
   */
  private fun unregisterActivityLifecycleCallbacks() {
    // 1. 读取并校验保存的 Application/callback，缺任一项都说明当前没有注册态。
    val application = lifecycleApplication ?: return
    val callbacks = activityLifecycleCallbacks ?: return

    // 2. 使用注册时的同一个 callback 对象反注册，避免 Application 持有旧插件实例。
    application.unregisterActivityLifecycleCallbacks(callbacks)
    activityLifecycleCallbacks = null
    lifecycleApplication = null
  }
}

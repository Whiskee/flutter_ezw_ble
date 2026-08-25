// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_native_connection_trace.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BleNativeConnectionTrace _$BleNativeConnectionTraceFromJson(
        Map<String, dynamic> json) =>
    BleNativeConnectionTrace(
      attemptId: json['attemptId'] as String,
      steps: (json['steps'] as List<dynamic>)
          .map((e) =>
              BleNativeConnectionTraceStep.fromJson(e as Map<String, dynamic>))
          .toList(),
      capturedElapsedMs: (json['capturedElapsedMs'] as num?)?.toInt(),
      lastRssiDbm: (json['lastRssiDbm'] as num?)?.toInt(),
      rssiAgeMs: (json['rssiAgeMs'] as num?)?.toInt(),
      phy: json['phy'] as String?,
      requestedPriority: json['requestedPriority'] as String?,
    );

Map<String, dynamic> _$BleNativeConnectionTraceToJson(
        BleNativeConnectionTrace instance) =>
    <String, dynamic>{
      'attemptId': instance.attemptId,
      'steps': instance.steps.map((e) => e.toJson()).toList(),
      'capturedElapsedMs': instance.capturedElapsedMs,
      'lastRssiDbm': instance.lastRssiDbm,
      'rssiAgeMs': instance.rssiAgeMs,
      'phy': instance.phy,
      'requestedPriority': instance.requestedPriority,
    };

BleNativeConnectionTraceStep _$BleNativeConnectionTraceStepFromJson(
        Map<String, dynamic> json) =>
    BleNativeConnectionTraceStep(
      stepSeq: (json['stepSeq'] as num).toInt(),
      stage: json['stage'] as String,
      result: json['result'] as String,
      elapsedMs: (json['elapsedMs'] as num).toInt(),
      serviceType: json['serviceType'] as String?,
      causeDomain: json['causeDomain'] as String?,
      causeCode: (json['causeCode'] as num?)?.toInt(),
      droppedCount: (json['droppedCount'] as num?)?.toInt(),
      bondState: json['bondState'] as String?,
      writeLimitBytes: (json['writeLimitBytes'] as num?)?.toInt(),
      linkTrigger: json['linkTrigger'] as String?,
      rssiBucket: json['rssiBucket'] as String?,
      phy: json['phy'] as String?,
      priorityAction: json['priorityAction'] as String?,
      actionResult: json['actionResult'] as String?,
    );

Map<String, dynamic> _$BleNativeConnectionTraceStepToJson(
        BleNativeConnectionTraceStep instance) =>
    <String, dynamic>{
      'stepSeq': instance.stepSeq,
      'stage': instance.stage,
      'result': instance.result,
      'elapsedMs': instance.elapsedMs,
      'serviceType': instance.serviceType,
      'causeDomain': instance.causeDomain,
      'causeCode': instance.causeCode,
      'droppedCount': instance.droppedCount,
      'bondState': instance.bondState,
      'writeLimitBytes': instance.writeLimitBytes,
      'linkTrigger': instance.linkTrigger,
      'rssiBucket': instance.rssiBucket,
      'phy': instance.phy,
      'priorityAction': instance.priorityAction,
      'actionResult': instance.actionResult,
    };

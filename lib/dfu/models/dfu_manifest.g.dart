// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dfu_manifest.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DfuManifest _$DfuManifestFromJson(Map<String, dynamic> json) => DfuManifest(
      (json['files'] as List<dynamic>)
          .map((e) => DfuManifestFile.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$DfuManifestToJson(DfuManifest instance) =>
    <String, dynamic>{
      'files': instance.files,
    };

DfuManifestFile _$DfuManifestFileFromJson(Map<String, dynamic> json) =>
    DfuManifestFile(
      json['file'] as String,
      json['image_index'] as String,
    );

Map<String, dynamic> _$DfuManifestFileToJson(DfuManifestFile instance) =>
    <String, dynamic>{
      'file': instance.fileName,
      'image_index': instance.imageIndex,
    };

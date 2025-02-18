import 'package:json_annotation/json_annotation.dart';

part 'dfu_manifest.g.dart';

@JsonSerializable()
class DfuManifest {
  final List<DfuManifestFile> files;

  DfuManifest(this.files);

  factory DfuManifest.fromJson(Map<String, dynamic> json) =>
      _$DfuManifestFromJson(json);

  Map<String, dynamic> toJson() => _$DfuManifestToJson(this);
}

@JsonSerializable()
class DfuManifestFile {
  @JsonKey(name: 'file')
  final String fileName;
  @JsonKey(name: 'image_index')
  final String imageIndex;

  DfuManifestFile(this.fileName, this.imageIndex);

  factory DfuManifestFile.fromJson(Map<String, dynamic> json) =>
      _$DfuManifestFileFromJson(json);

  Map<String, dynamic> toJson() => _$DfuManifestFileToJson(this);
}

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ServerConfig _$ServerConfigFromJson(Map<String, dynamic> json) =>
    _ServerConfig(
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 8765,
    );

Map<String, dynamic> _$ServerConfigToJson(_ServerConfig instance) =>
    <String, dynamic>{'host': instance.host, 'port': instance.port};

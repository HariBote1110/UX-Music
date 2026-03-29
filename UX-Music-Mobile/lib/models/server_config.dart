import 'package:freezed_annotation/freezed_annotation.dart';

part 'server_config.freezed.dart';
part 'server_config.g.dart';

@freezed
abstract class ServerConfig with _$ServerConfig {
  const factory ServerConfig({
    @Default('') String host,
    @Default(8765) int port,
  }) = _ServerConfig;

  const ServerConfig._();

  factory ServerConfig.fromJson(Map<String, dynamic> json) =>
      _$ServerConfigFromJson(json);

  String get baseUrl =>
      host.isNotEmpty ? 'http://$host:$port' : 'http://localhost:$port';
  bool get isConfigured => host.isNotEmpty;
}

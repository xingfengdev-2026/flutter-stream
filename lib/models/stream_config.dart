import 'dart:convert';

class ServerConfig {
  String name;
  String url;
  String streamKey;

  ServerConfig({
    required this.name,
    required this.url,
    this.streamKey = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'streamKey': streamKey,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        name: json['name'] as String,
        url: json['url'] as String,
        streamKey: json['streamKey'] as String? ?? '',
      );

  String encode() => jsonEncode(toJson());
  static ServerConfig decode(String s) =>
      ServerConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);
}

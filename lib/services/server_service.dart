import 'package:shared_preferences/shared_preferences.dart';
import '../models/stream_config.dart';

class ServerService {
  static const _key = 'saved_servers';

  Future<List<ServerConfig>> getServers() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(_key) ?? [];
    return data.map((e) => ServerConfig.decode(e)).toList();
  }

  Future<void> saveServers(List<ServerConfig> servers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      servers.map((e) => e.encode()).toList(),
    );
  }

  Future<void> addServer(ServerConfig server) async {
    final servers = await getServers();
    servers.add(server);
    await saveServers(servers);
  }

  Future<void> updateServer(int index, ServerConfig server) async {
    final servers = await getServers();
    if (index < servers.length) {
      servers[index] = server;
      await saveServers(servers);
    }
  }

  Future<void> removeServer(int index) async {
    final servers = await getServers();
    if (index < servers.length) {
      servers.removeAt(index);
      await saveServers(servers);
    }
  }
}

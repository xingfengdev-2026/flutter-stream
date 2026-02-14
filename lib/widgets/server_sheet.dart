import 'package:flutter/material.dart';
import '../models/stream_config.dart';
import '../providers/stream_provider.dart';

class ServerSheet extends StatefulWidget {
  final LiveStreamProvider provider;

  const ServerSheet({super.key, required this.provider});

  @override
  State<ServerSheet> createState() => _ServerSheetState();
}

class _ServerSheetState extends State<ServerSheet> {
  LiveStreamProvider get _p => widget.provider;
  List<ServerConfig> _servers = [];

  @override
  void initState() {
    super.initState();
    _servers = List.of(_p.servers);
    _p.addListener(_onProviderChanged);
  }

  @override
  void dispose() {
    _p.removeListener(_onProviderChanged);
    super.dispose();
  }

  void _onProviderChanged() {
    if (mounted) {
      setState(() => _servers = List.of(_p.servers));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF181620),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
            child: Row(
              children: [
                const Icon(Icons.cell_tower_rounded,
                    color: Color(0xFF818CF8), size: 22),
                const SizedBox(width: 10),
                const Text(
                  'Stream Servers',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline,
                      color: Color(0xFF818CF8)),
                  onPressed: () => _showAddEditDialog(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_servers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  Icon(Icons.dns_outlined,
                      color: Colors.white.withValues(alpha: 0.15), size: 48),
                  const SizedBox(height: 12),
                  Text(
                    'No servers yet',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tap + to add your RTMP server',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.2),
                        fontSize: 12),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                itemCount: _servers.length,
                itemBuilder: (_, i) {
                  final server = _servers[i];
                  return _ServerTile(
                    server: server,
                    onTap: () => Navigator.pop(context, server),
                    onEdit: () => _showAddEditDialog(index: i),
                    onDelete: () => _confirmDelete(i),
                  );
                },
              ),
            ),
          SizedBox(height: 16 + bottom),
        ],
      ),
    );
  }

  void _showAddEditDialog({int? index}) {
    final isEdit = index != null;
    final server = isEdit ? _servers[index] : null;
    final nameCtrl = TextEditingController(text: server?.name ?? '');
    final urlCtrl = TextEditingController(text: server?.url ?? '');
    final keyCtrl = TextEditingController(text: server?.streamKey ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          isEdit ? 'Edit Server' : 'Add Server',
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogField(nameCtrl, 'Name', 'e.g. My Server'),
              const SizedBox(height: 12),
              _dialogField(urlCtrl, 'RTMP URL', 'rtmp://server.com/live'),
              const SizedBox(height: 12),
              _dialogField(keyCtrl, 'Stream Key', 'your-stream-key'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
            onPressed: () {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              final cfg = ServerConfig(
                name: name,
                url: url,
                streamKey: keyCtrl.text.trim(),
              );
              if (isEdit) {
                _p.updateServer(index, cfg);
              } else {
                _p.addServer(cfg);
              }
              Navigator.pop(ctx);
            },
            child: Text(isEdit ? 'Save' : 'Add'),
          ),
        ],
      ),
    );
  }

  Widget _dialogField(
      TextEditingController ctrl, String label, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white38, fontSize: 13),
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.15)),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  void _confirmDelete(int index) {
    final name = _servers[index].name;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Server?',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Text(
          'Remove "$name"?',
          style: const TextStyle(color: Colors.white54),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () {
              _p.removeServer(index);
              Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final ServerConfig server;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ServerTile({
    required this.server,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 8),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [
                const Color(0xFF6366F1).withValues(alpha: 0.3),
                const Color(0xFF06B6D4).withValues(alpha: 0.3),
              ],
            ),
          ),
          child: const Icon(Icons.dns_rounded,
              color: Color(0xFF818CF8), size: 20),
        ),
        title: Text(
          server.name,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          server.url,
          style: const TextStyle(color: Colors.white30, fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  color: Colors.white24, size: 18),
              onPressed: onEdit,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.white24, size: 18),
              onPressed: onDelete,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

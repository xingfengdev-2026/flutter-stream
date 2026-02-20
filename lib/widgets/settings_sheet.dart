import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/stream_config.dart';
import '../providers/stream_provider.dart';

class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Consumer<LiveStreamProvider>(
      builder: (context, p, _) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Container(
            color: const Color(0xFF181620),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + bottom),
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Row(
                  children: [
                    Icon(Icons.tune_rounded, color: Color(0xFF818CF8), size: 22),
                    SizedBox(width: 10),
                    Text(
                      'Settings',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Camera
                _sectionTitle('Camera'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _CameraOption(
                      icon: Icons.camera_rear_rounded,
                      label: 'Back',
                      selected: !p.isFrontCamera,
                      onTap: p.isLocked ? null : () => p.setCameraPosition(false),
                    ),
                    const SizedBox(width: 10),
                    _CameraOption(
                      icon: Icons.camera_front_rounded,
                      label: 'Front',
                      selected: p.isFrontCamera,
                      onTap: p.isLocked ? null : () => p.setCameraPosition(true),
                    ),
                  ],
                ),
                // Back camera lens picker
                if (!p.isFrontCamera && p.backCameras.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _sectionTitle('Lens'),
                  const SizedBox(height: 8),
                  _LensChipRow(
                    cameras: p.backCameras,
                    selectedId:
                        p.selectedCameraId ?? (p.backCameras.first['id'] ?? ''),
                    onSelected: p.isLocked
                        ? null
                        : (cameraId) => p.selectCamera(cameraId),
                  ),
                ],
                const SizedBox(height: 22),

                // Zoom slider
                if (p.maxZoom > 1.0 || p.minZoom < 1.0) ...[
                  _sectionTitle('Zoom (${p.currentZoom.toStringAsFixed(1)}x)'),
                  const SizedBox(height: 4),
                  SliderTheme(
                    data: SliderThemeData(
                      activeTrackColor: const Color(0xFF6366F1),
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
                      thumbColor: const Color(0xFF818CF8),
                      overlayColor: const Color(0xFF6366F1).withValues(alpha: 0.2),
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    ),
                    child: Slider(
                      value: p.currentZoom.clamp(p.minZoom, p.maxZoom),
                      min: p.minZoom,
                      max: p.maxZoom,
                      onChanged: p.isLocked ? null : (v) => p.setZoom(v),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // Resolution
                _sectionTitle('Resolution'),
                const SizedBox(height: 8),
                _ChipRow(
                  options: const [
                    'Native',
                    '240p',
                    '360p',
                    '480p',
                    '720p',
                    '1080p',
                    '1440p',
                    '2160p',
                  ],
                  selected: p.resolution,
                  onSelected: p.isLocked ? null : p.setResolution,
                ),
                const SizedBox(height: 22),

                // FPS
                _sectionTitle('Frame Rate'),
                const SizedBox(height: 8),
                _ChipRow(
                  options: const ['Native', '15 fps', '24 fps', '30 fps'],
                  selected: p.isNativeFps ? 'Native' : '${p.customFps} fps',
                  onSelected: p.isLocked ? null : (v) {
                    if (v == 'Native') {
                      p.setFpsNative();
                    } else {
                      p.setFpsCustom(int.parse(v.split(' ').first));
                    }
                  },
                ),
                const SizedBox(height: 22),

                // Stream Servers
                Row(
                  children: [
                    _sectionTitle('Stream Servers'),
                    const Spacer(),
                    GestureDetector(
                      onTap: p.isLocked ? null : () => _showAddEditServerDialog(context, p),
                      child: Icon(Icons.add_circle_outline,
                          color: p.isLocked ? Colors.white24 : const Color(0xFF818CF8),
                          size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (p.servers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(
                        'No servers yet — tap + to add',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.25),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  )
                else
                  ...List.generate(p.servers.length, (i) {
                    final s = p.servers[i];
                    return _ServerRow(
                      server: s,
                      onEdit: p.isLocked ? null : () => _showAddEditServerDialog(context, p, index: i),
                      onDelete: p.isLocked ? null : () => _confirmDeleteServer(context, p, i),
                    );
                  }),
                const SizedBox(height: 8),
              ],
            ),
          ),
          ),
        );
      },
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white54,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
      ),
    );
  }

  void _showAddEditServerDialog(BuildContext context, LiveStreamProvider p, {int? index}) {
    if (p.isLocked) return;
    final isEdit = index != null;
    final server = isEdit ? p.servers[index] : null;
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
              _dialogField(keyCtrl, 'Stream Key (optional)', 'leave empty if not needed'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
            onPressed: p.isLocked ? null : () {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              final cfg = ServerConfig(name: name, url: url, streamKey: keyCtrl.text.trim());
              if (isEdit) {
                p.updateServer(index, cfg);
              } else {
                p.addServer(cfg);
              }
              Navigator.pop(ctx);
            },
            child: Text(isEdit ? 'Save' : 'Add'),
          ),
        ],
      ),
    );
  }

  Widget _dialogField(TextEditingController ctrl, String label, String hint) {
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  void _confirmDeleteServer(BuildContext context, LiveStreamProvider p, int index) {
    if (p.isLocked) return;
    final name = p.servers[index].name;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Server?', style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Text('Remove "$name"?', style: const TextStyle(color: Colors.white54)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () {
              p.removeServer(index);
              Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

// ─── Camera Option ───────────────────────────────────────

class _CameraOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _CameraOption({
    required this.icon,
    required this.label,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected
                ? const Color(0xFF6366F1).withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.04),
            border: Border.all(
              color: selected
                  ? const Color(0xFF6366F1).withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.06),
            ),
          ),
          child: Column(
            children: [
              Icon(icon,
                  color: selected ? const Color(0xFF818CF8) : Colors.white38,
                  size: 28),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white38,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Server Row ──────────────────────────────────────────

class _ServerRow extends StatelessWidget {
  final ServerConfig server;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _ServerRow({
    required this.server,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.dns_rounded, color: Color(0xFF818CF8), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  server.name,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                ),
                Text(
                  server.url,
                  style: const TextStyle(color: Colors.white30, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onEdit,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.edit_outlined,
                color: onEdit == null ? Colors.white12 : Colors.white24,
                size: 16,
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onDelete,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.delete_outline,
                color: onDelete == null ? Colors.white12 : Colors.white24,
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LensChipRow extends StatelessWidget {
  final List<Map<String, String>> cameras;
  final String selectedId;
  final ValueChanged<String>? onSelected;

  const _LensChipRow({
    required this.cameras,
    required this.selectedId,
    this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: cameras.map((camera) {
        final id = camera['id'] ?? '';
        final label = camera['label'] ?? id;
        final isSel = id == selectedId;
        return GestureDetector(
          onTap: (onSelected != null && id.isNotEmpty)
              ? () => onSelected!(id)
              : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: isSel
                  ? const Color(0xFF6366F1)
                  : Colors.white.withValues(alpha: 0.06),
              border: isSel
                  ? null
                  : Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: isSel ? Colors.white : Colors.white54,
                fontSize: 13,
                fontWeight: isSel ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _ChipRow extends StatelessWidget {
  final List<String> options;
  final String selected;
  final ValueChanged<String>? onSelected;

  const _ChipRow({
    required this.options,
    required this.selected,
    this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((opt) {
        final isSel = opt == selected;
        return GestureDetector(
          onTap: onSelected != null ? () => onSelected!(opt) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: isSel
                  ? const Color(0xFF6366F1)
                  : Colors.white.withValues(alpha: 0.06),
              border: isSel
                  ? null
                  : Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Text(
              opt,
              style: TextStyle(
                color: isSel ? Colors.white : Colors.white54,
                fontSize: 13,
                fontWeight: isSel ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

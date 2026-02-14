import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/stream_provider.dart';

class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Consumer<LiveStreamProvider>(
      builder: (context, p, _) {
        final locked = p.status != StreamStatus.idle;
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
                if (locked)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            color: Colors.amber.shade600, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          'Stop streaming to change settings',
                          style: TextStyle(
                              color: Colors.amber.shade600, fontSize: 12),
                        ),
                      ],
                    ),
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
                      onTap: locked ? null : () => p.setCameraPosition(false),
                    ),
                    const SizedBox(width: 10),
                    _CameraOption(
                      icon: Icons.camera_front_rounded,
                      label: 'Front',
                      selected: p.isFrontCamera,
                      onTap: locked ? null : () => p.setCameraPosition(true),
                    ),
                  ],
                ),
                const SizedBox(height: 22),

                // Resolution
                _sectionTitle('Resolution'),
                const SizedBox(height: 8),
                _ChipRow(
                  options: const [
                    'Native',
                    '360p',
                    '720p',
                    '1080p',
                    '2K',
                    '4K',
                  ],
                  selected: p.resolution,
                  onSelected: locked ? null : p.setResolution,
                ),
                const SizedBox(height: 22),

                // FPS
                _sectionTitle('Frame Rate'),
                const SizedBox(height: 8),
                _ChipRow(
                  options: const ['Native', '15 fps', '24 fps', '30 fps', '60 fps'],
                  selected: p.isNativeFps ? 'Native' : '${p.customFps} fps',
                  onSelected: locked
                      ? null
                      : (v) {
                          if (v == 'Native') {
                            p.setFpsNative();
                          } else {
                            p.setFpsCustom(int.parse(v.split(' ').first));
                          }
                        },
                ),
                const SizedBox(height: 22),

                // Bitrate
                _sectionTitle('Max Bitrate'),
                const SizedBox(height: 8),
                _BitrateSection(
                  isNative: p.isNativeBitrate,
                  customBitrate: p.customBitrate,
                  locked: locked,
                  onSetNative: p.setBitrateNative,
                  onSetCustom: p.setBitrateCustom,
                ),
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
}

// ─── Bitrate Section (Native toggle + custom input) ──────

class _BitrateSection extends StatelessWidget {
  final bool isNative;
  final int customBitrate;
  final bool locked;
  final VoidCallback onSetNative;
  final ValueChanged<int> onSetCustom;

  const _BitrateSection({
    required this.isNative,
    required this.customBitrate,
    required this.locked,
    required this.onSetNative,
    required this.onSetCustom,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Native / Custom toggle chips
        Row(
          children: [
            _MiniChip(
              label: 'Native',
              selected: isNative,
              onTap: locked ? null : onSetNative,
            ),
            const SizedBox(width: 8),
            _MiniChip(
              label: 'Custom',
              selected: !isNative,
              onTap: locked
                  ? null
                  : () {
                      if (isNative) onSetCustom(customBitrate);
                    },
            ),
          ],
        ),
        // Show input only when Custom is selected
        if (!isNative) ...[
          const SizedBox(height: 10),
          _BitrateInput(
            bitrate: customBitrate,
            locked: locked,
            onChanged: onSetCustom,
          ),
        ],
      ],
    );
  }
}

// ─── Mini Chip for Native/Custom toggle ──────────────────

class _MiniChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _MiniChip({
    required this.label,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected
              ? const Color(0xFF6366F1)
              : Colors.white.withValues(alpha: 0.06),
          border: selected
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white54,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ─── Bitrate Input ───────────────────────────────────────

class _BitrateInput extends StatefulWidget {
  final int bitrate;
  final bool locked;
  final ValueChanged<int> onChanged;

  const _BitrateInput({
    required this.bitrate,
    required this.locked,
    required this.onChanged,
  });

  @override
  State<_BitrateInput> createState() => _BitrateInputState();
}

class _BitrateInputState extends State<_BitrateInput> {
  late TextEditingController _textCtrl;
  bool _isMbps = true;

  @override
  void initState() {
    super.initState();
    if (widget.bitrate >= 1000000) {
      _isMbps = true;
      final mbps = widget.bitrate / 1000000;
      _textCtrl = TextEditingController(text: _formatNumber(mbps));
    } else {
      _isMbps = false;
      final kbps = widget.bitrate / 1000;
      _textCtrl = TextEditingController(text: _formatNumber(kbps));
    }
  }

  String _formatNumber(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  @override
  void didUpdateWidget(_BitrateInput old) {
    super.didUpdateWidget(old);
    if (old.bitrate != widget.bitrate) {
      final val = _isMbps
          ? widget.bitrate / 1000000
          : widget.bitrate / 1000;
      _textCtrl.text = _formatNumber(val);
    }
  }

  void _apply() {
    final val = double.tryParse(_textCtrl.text);
    if (val == null || val <= 0) return;
    final bps = _isMbps ? (val * 1000000).toInt() : (val * 1000).toInt();
    widget.onChanged(bps);
  }

  void _toggleUnit() {
    if (widget.locked) return;
    final currentBps = _isMbps
        ? (double.tryParse(_textCtrl.text) ?? 0) * 1000000
        : (double.tryParse(_textCtrl.text) ?? 0) * 1000;

    setState(() {
      _isMbps = !_isMbps;
      final newVal = _isMbps ? currentBps / 1000000 : currentBps / 1000;
      _textCtrl.text = _formatNumber(newVal);
    });
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: TextField(
              controller: _textCtrl,
              enabled: !widget.locked,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
              ],
              onChanged: (_) => _apply(),
              onSubmitted: (_) => _apply(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: InputBorder.none,
                hintText: _isMbps ? 'e.g. 10' : 'e.g. 5000',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.2),
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Unit toggle
        GestureDetector(
          onTap: _toggleUnit,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF6366F1).withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isMbps ? 'Mbps' : 'Kbps',
                  style: const TextStyle(
                    color: Color(0xFF818CF8),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.swap_horiz_rounded,
                    color: Color(0xFF818CF8), size: 16),
              ],
            ),
          ),
        ),
      ],
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

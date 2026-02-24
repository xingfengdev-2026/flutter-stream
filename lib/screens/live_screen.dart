import 'package:apivideo_live_stream/apivideo_live_stream.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../models/stream_config.dart';
import '../providers/stream_provider.dart';
import '../widgets/server_sheet.dart';
import '../widgets/settings_sheet.dart';

class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> with WidgetsBindingObserver {
  late final LiveStreamProvider _provider;
  ApiVideoLiveStreamController? _controller;
  bool _permissionsGranted = false;
  bool _isInitialized = false;

  int _recreateGen = 0;

  bool _wasLiveBeforePause = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _provider = Provider.of<LiveStreamProvider>(context, listen: false);
    _provider.onControllerNeedsRecreate = _recreateController;
    _requestPermissions();
  }

  @override
  void dispose() {
    _recreateGen++;
    _provider.onControllerNeedsRecreate = null;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[OnAir] Lifecycle: $state');

    final isLive =
        _provider.status == StreamStatus.streaming ||
        _provider.status == StreamStatus.connecting ||
        _provider.status == StreamStatus.reconnecting;

    if (state == AppLifecycleState.inactive) {
      if (isLive) _wasLiveBeforePause = true;
      if (!isLive && _isInitialized) {
        _controller?.stopPreview();
      }
    } else if (state == AppLifecycleState.paused) {
      if (isLive) _wasLiveBeforePause = true;
    } else if (state == AppLifecycleState.resumed) {
      if (_wasLiveBeforePause &&
          !_provider.userStopped &&
          _provider.activeServer != null) {
        _wasLiveBeforePause = false;

        if (_provider.status == StreamStatus.streaming) {
          debugPrint('[OnAir] Resumed — stream still alive, hands off');
          _provider.armResumeGrace();
        } else {
          debugPrint(
            '[OnAir] Resumed — stream died in background, recreating...',
          );
          _provider.notifyResumeFromBackground();
          _recreateController();
        }
      } else {
        _wasLiveBeforePause = false;
        if (_isInitialized && !(_provider.status == StreamStatus.streaming)) {
          _controller?.startPreview();
        }
      }
    }
  }

  Future<void> _requestPermissions() async {
    final camera = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    if (camera.isGranted && mic.isGranted) {
      setState(() => _permissionsGranted = true);
      _initCamera();
    } else {
      setState(() => _permissionsGranted = false);
    }
  }

  Future<void> _initCamera() async {
    _recreateGen++;
    final myGen = _recreateGen;
    _controller = ApiVideoLiveStreamController(
      initialAudioConfig: AudioConfig(),
      initialVideoConfig: _provider.buildVideoConfig(),
      initialCameraPosition: _provider.isFrontCamera
          ? CameraPosition.front
          : CameraPosition.back,
      onConnectionSuccess: () {
        if (_recreateGen == myGen) _provider.onConnectionSuccess();
      },
      onConnectionFailed: (error) {
        if (_recreateGen == myGen) _provider.onConnectionFailed(error);
      },
      onDisconnection: () {
        if (_recreateGen == myGen) _provider.onDisconnect();
      },
    );
    await _controller!.initialize();
    if (_recreateGen != myGen || !mounted) return;
    _provider.initController(_controller!);
    setState(() => _isInitialized = true);
  }

  Future<void> _recreateController() async {
    _recreateGen++;
    final myGen = _recreateGen;
    debugPrint('[OnAir] Recreating controller (gen=$myGen)...');

    final oldController = _controller;
    _controller = null;
    _isInitialized = false;
    _provider.clearController();

    if (oldController != null) {
      Future.microtask(() {
        try {
          oldController.dispose();
        } catch (_) {}
      });
    }

    await Future.delayed(const Duration(milliseconds: 300));
    if (_recreateGen != myGen || !mounted) return;

    try {
      final ctrl = ApiVideoLiveStreamController(
        initialAudioConfig: AudioConfig(),
        initialVideoConfig: _provider.buildVideoConfig(),
        initialCameraPosition: _provider.isFrontCamera
            ? CameraPosition.front
            : CameraPosition.back,
        onConnectionSuccess: () {
          if (_recreateGen == myGen) _provider.onConnectionSuccess();
        },
        onConnectionFailed: (error) {
          if (_recreateGen == myGen) _provider.onConnectionFailed(error);
        },
        onDisconnection: () {
          if (_recreateGen == myGen) _provider.onDisconnect();
        },
      );
      await ctrl.initialize();

      if (_recreateGen != myGen || !mounted) {
        Future.microtask(() {
          try {
            ctrl.dispose();
          } catch (_) {}
        });
        return;
      }

      _controller = ctrl;
      _provider.initController(ctrl);
      setState(() => _isInitialized = true);

      debugPrint('[OnAir] Controller recreated successfully (gen=$myGen)');

      if (_provider.activeServer != null && !_provider.userStopped) {
        _provider.attemptConnect(_provider.activeServer!);
      }
    } catch (e) {
      debugPrint('[OnAir] Controller recreation failed: $e');
      if (_recreateGen != myGen || !mounted) return;
      await Future.delayed(const Duration(seconds: 1));
      if (_recreateGen == myGen &&
          mounted &&
          _provider.activeServer != null &&
          !_provider.userStopped) {
        _recreateController();
      }
    }
  }

  void _onRecordTap() async {
    if (_provider.status == StreamStatus.streaming ||
        _provider.status == StreamStatus.connecting ||
        _provider.status == StreamStatus.reconnecting) {
      await _provider.stopStreaming();
      return;
    }

    final server = await showModalBottomSheet<ServerConfig>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ServerSheet(provider: _provider),
    );
    if (server != null && mounted) {
      await _provider.startStreamingWithFreshController(server);
    }
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: _provider,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: const SettingsSheet(),
        ),
      ),
    );
  }

  double _baseZoom = 1.0;

  void _onScaleStart(ScaleStartDetails details) {
    _baseZoom = _provider.currentZoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final newZoom = _baseZoom * details.scale;
    _provider.setZoom(newZoom);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_permissionsGranted && _isInitialized && _controller != null)
            GestureDetector(
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              child: ApiVideoCameraPreview(
                controller: _controller!,
                fit: BoxFit.cover,
              ),
            )
          else if (!_permissionsGranted)
            _PermissionPlaceholder(onRetry: _requestPermissions)
          else
            const Center(
              child: CircularProgressIndicator(
                color: Color(0xFF6366F1),
                strokeWidth: 2,
              ),
            ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: RepaintBoundary(child: _TopBar()),
          ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: RepaintBoundary(
              child: _BottomControls(
                onRecord: _onRecordTap,
                onSettings: _showSettings,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Consumer<LiveStreamProvider>(
            builder: (_, p, child) {
              final isLive = p.status == StreamStatus.streaming;
              final isReconnecting = p.status == StreamStatus.reconnecting;
              return Row(
                children: [
                  if (isLive || isReconnecting) ...[
                    _PulsingDot(
                      color: isReconnecting ? Colors.orange : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isReconnecting ? 'RECONNECTING' : 'LIVE',
                      style: TextStyle(
                        color: isReconnecting ? Colors.orange : Colors.red,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(width: 12),
                    _badge(p.formattedDuration, Colors.white),
                  ],
                  const Spacer(),
                  _badge(p.resolution, Colors.white60),
                  if ((isLive || isReconnecting) && p.activeServer != null) ...[
                    const SizedBox(width: 8),
                    _badge(p.activeServer!.name, Colors.white60),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontFamily: 'monospace'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _BottomControls extends StatelessWidget {
  final VoidCallback onRecord;
  final VoidCallback onSettings;

  const _BottomControls({required this.onRecord, required this.onSettings});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Consumer<LiveStreamProvider>(
          builder: (_, p, child) {
            final isLive = p.status == StreamStatus.streaming;
            final isConnecting = p.status == StreamStatus.connecting;
            final isReconnecting = p.status == StreamStatus.reconnecting;

            return Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 50),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.status == StreamStatus.error)
                    _StatusBanner(
                      color: Colors.red,
                      icon: const Icon(
                        Icons.error_outline,
                        color: Colors.white,
                        size: 16,
                      ),
                      text: p.errorMessage,
                    ),
                  if (isReconnecting)
                    _StatusBanner(
                      color: Colors.orange,
                      icon: const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      ),
                      text: p.errorMessage,
                    ),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CircleButton(
                        icon: p.isMuted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        label: p.isMuted ? 'Unmute' : 'Mute',
                        active: p.isMuted,
                        onTap: p.isLocked ? null : p.toggleMute,
                      ),
                      _CircleButton(
                        icon: p.isLocked
                            ? Icons.lock_rounded
                            : Icons.lock_open_rounded,
                        label: p.isLocked ? 'Locked' : 'Lock',
                        active: p.isLocked,
                        onTap: p.toggleLock,
                      ),
                      _RecordButton(
                        isLive: isLive || isReconnecting,
                        isConnecting: isConnecting,
                        onTap: onRecord,
                      ),
                      _CircleButton(
                        icon: Icons.tune_rounded,
                        label: 'Settings',
                        onTap: p.isLocked ? null : onSettings,
                      ),
                      _CircleButton(
                        icon: Icons.cameraswitch_rounded,
                        label: 'Flip',
                        onTap: p.isLocked ? null : p.toggleCamera,
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final Color color;
  final Widget icon;
  final String text;

  const _StatusBanner({
    required this.color,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12, left: 32, right: 32),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  const _CircleButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: !enabled
                  ? Colors.white.withValues(alpha: 0.06)
                  : active
                  ? Colors.red.withValues(alpha: 0.3)
                  : Colors.white.withValues(alpha: 0.12),
            ),
            child: Icon(
              icon,
              color: !enabled
                  ? Colors.white30
                  : active
                  ? Colors.red.shade300
                  : Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: enabled ? Colors.white60 : Colors.white38,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  final bool isLive;
  final bool isConnecting;
  final VoidCallback onTap;

  const _RecordButton({
    required this.isLive,
    required this.isConnecting,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isConnecting ? null : onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isLive ? Colors.red : Colors.white,
                width: 3,
              ),
            ),
            padding: const EdgeInsets.all(3),
            child: Center(
              child: isConnecting
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.red,
                        strokeWidth: 2.5,
                      ),
                    )
                  : AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeInOut,
                      width: isLive ? 24 : 58,
                      height: isLive ? 24 : 58,
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(isLive ? 6 : 29),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isLive
                ? 'Stop'
                : isConnecting
                ? 'Connecting'
                : 'Go Live',
            style: TextStyle(
              color: isLive ? Colors.red.shade300 : Colors.white60,
              fontSize: 11,
              fontWeight: isLive ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({this.color = Colors.red});
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FadeTransition(
        opacity: Tween(begin: 0.3, end: 1.0).animate(_ctrl),
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
          ),
        ),
      ),
    );
  }
}

class _PermissionPlaceholder extends StatelessWidget {
  final VoidCallback onRetry;
  const _PermissionPlaceholder({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F0A1F),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_rounded,
              color: Colors.white24,
              size: 56,
            ),
            const SizedBox(height: 16),
            const Text(
              'Camera & Microphone access needed',
              style: TextStyle(color: Colors.white38, fontSize: 15),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Grant Permissions'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF818CF8),
                side: const BorderSide(color: Color(0xFF6366F1)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

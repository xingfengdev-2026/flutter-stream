import 'dart:async';
import 'dart:io';
import 'package:apivideo_live_stream/apivideo_live_stream.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/stream_config.dart';
import '../services/foreground_service.dart';
import '../services/server_service.dart';

enum StreamStatus { idle, connecting, streaming, reconnecting, error }

class LiveStreamProvider extends ChangeNotifier {
  final ServerService _serverService = ServerService();

  ApiVideoLiveStreamController? _controller;
  ApiVideoLiveStreamController? get controller => _controller;

  StreamStatus _status = StreamStatus.idle;
  StreamStatus get status => _status;

  String _errorMessage = '';
  String get errorMessage => _errorMessage;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;
  Timer? _timer;

  Timer? _reconnectTimer;
  Timer? _retryTimer;
  int _reconnectAttempt = 0;
  bool userStopped = false;

  bool _controllerBusy = false;
  bool _pendingReconnect = false;
  bool _selfStopping = false;

  /// Generation counter: incremented on every force-reconnect / stop.
  /// Any in-flight attemptConnect with a stale generation bails out
  /// without touching shared state, preventing race conditions.
  int _generation = 0;

  Timer? _watchdogTimer;

  /// True while live_screen is recreating the native controller.
  /// Watchdog must NOT fire during this period — the controller is
  /// intentionally null and no timers are running.
  bool _recreationPending = false;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult> _lastConnectivity = [];
  Timer? _networkDebounce;

  /// Timestamp until which disconnect callbacks are suppressed.
  /// Set when resuming from background while stream is alive — the Flutter
  /// texture lifecycle may fire spurious native disconnect callbacks.
  DateTime _resumeGraceUntil = DateTime(0);

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _isFrontCamera = false;
  bool get isFrontCamera => _isFrontCamera;

  String _resolution = 'Native';
  String get resolution => _resolution;

  bool _isNativeBitrate = true;
  bool get isNativeBitrate => _isNativeBitrate;
  int _customBitrate = 10000000;
  int get customBitrate => _customBitrate;

  bool _isNativeFps = true;
  bool get isNativeFps => _isNativeFps;
  int _customFps = 30;
  int get customFps => _customFps;

  String get fpsDisplay => _isNativeFps ? 'Native' : '$_customFps fps';

  List<ServerConfig> _servers = [];
  List<ServerConfig> get servers => _servers;

  ServerConfig? _activeServer;
  ServerConfig? get activeServer => _activeServer;

  int get reconnectAttempt => _reconnectAttempt;

  VoidCallback? onControllerNeedsRecreate;

  LiveStreamProvider() {
    _loadServers();
    _initConnectivityListener();
  }

  // ─── Network change detection ─────────────────────────

  void _initConnectivityListener() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      final changed = _lastConnectivity.toString() != result.toString();
      _lastConnectivity = result;
      if (!changed) return;

      debugPrint('[OnAir] Network changed: $result');

      final isActive = _status == StreamStatus.streaming ||
          _status == StreamStatus.connecting ||
          _status == StreamStatus.reconnecting;

      if (isActive && _activeServer != null && !userStopped) {
        final hasNetwork = result.any((r) =>
            r == ConnectivityResult.wifi ||
            r == ConnectivityResult.mobile ||
            r == ConnectivityResult.ethernet);

        if (hasNetwork) {
          // Debounce: wait for network to stabilize before acting.
          _networkDebounce?.cancel();
          _networkDebounce = Timer(const Duration(milliseconds: 800), () {
            if (userStopped || _activeServer == null) return;
            // If still streaming fine, don't disrupt.
            if (_status == StreamStatus.streaming) {
              debugPrint('[OnAir] Network changed but stream still alive — skipping reconnect');
              return;
            }
            debugPrint('[OnAir] Network stable, forcing reconnect...');
            _forceReconnect();
          });
        }
      }
    });
  }

  /// Nuclear reconnect: invalidate all in-flight operations, recreate controller.
  void _forceReconnect() {
    // Bump generation — any running attemptConnect becomes stale and will
    // bail out without touching _controllerBusy or any other state.
    _generation++;
    _reconnectTimer?.cancel();
    _retryTimer?.cancel();
    _reconnectAttempt = 0;
    // Force-reset mutex — the old controller is about to be destroyed,
    // so whatever was "busy" on it is now irrelevant.
    _controllerBusy = false;
    _selfStopping = false;
    _pendingReconnect = false;

    if (onControllerNeedsRecreate != null) {
      _recreationPending = true;
      _status = StreamStatus.reconnecting;
      _errorMessage = 'Network changed, reconnecting...';
      notifyListeners();
      onControllerNeedsRecreate!();
    } else {
      _scheduleReconnect();
    }
  }

  Future<void> _loadServers() async {
    _servers = await _serverService.getServers();
    notifyListeners();
  }

  Future<void> addServer(ServerConfig server) async {
    await _serverService.addServer(server);
    await _loadServers();
  }

  Future<void> updateServer(int index, ServerConfig server) async {
    await _serverService.updateServer(index, server);
    await _loadServers();
  }

  Future<void> removeServer(int index) async {
    await _serverService.removeServer(index);
    await _loadServers();
  }

  void initController(ApiVideoLiveStreamController controller) {
    _controller = controller;
    _recreationPending = false;
    notifyListeners();
    // Sync pending settings (e.g. mute set before streaming) to the new controller.
    _applyPendingSettings();
  }

  /// Push all user-chosen settings to the current native controller.
  /// Called after every controller creation / recreation so that
  /// pre-set values (mute, video config) are not lost.
  Future<void> _applyPendingSettings() async {
    if (_controller == null) return;
    try {
      await _controller!.setIsMuted(_isMuted);
    } catch (_) {}
  }

  void clearController() {
    _controller = null;
    notifyListeners();
  }

  /// Suppress disconnect callbacks for 3 seconds after returning to foreground.
  /// The Flutter TextureView lifecycle can fire spurious native callbacks
  /// when the surface is destroyed / recreated by the framework.
  void armResumeGrace() {
    _resumeGraceUntil = DateTime.now().add(const Duration(seconds: 3));
    debugPrint('[OnAir] Resume grace armed for 3s');
  }

  bool get _inResumeGrace => DateTime.now().isBefore(_resumeGraceUntil);

  /// Called when app resumes from screen-off while we were live.
  /// Resets state so the new controller can reconnect cleanly.
  void notifyResumeFromBackground() {
    _generation++;
    _controllerBusy = false;
    _selfStopping = false;
    _pendingReconnect = false;
    _recreationPending = true;
    _reconnectTimer?.cancel();
    _retryTimer?.cancel();
    _reconnectAttempt = 0;
    _status = StreamStatus.reconnecting;
    _errorMessage = 'Resuming stream...';
    notifyListeners();
  }

  /// Start streaming with a guaranteed fresh controller.
  /// Requests controller recreation first, then connects.
  Future<void> startStreamingWithFreshController(ServerConfig server) async {
    _generation++;
    _activeServer = server;
    _status = StreamStatus.connecting;
    _errorMessage = '';
    userStopped = false;
    _reconnectAttempt = 0;
    _pendingReconnect = false;
    _controllerBusy = false;
    _selfStopping = false;
    notifyListeners();

    ForegroundService.start();
    WakelockPlus.enable();
    _startWatchdog();

    // Request live_screen to recreate controller.
    // It will call initController + attemptConnect when done.
    if (onControllerNeedsRecreate != null) {
      _recreationPending = true;
      onControllerNeedsRecreate!();
    } else {
      // Fallback: use existing controller
      await attemptConnect(server);
    }
  }

  // ─── Settings ──────────────────────────────────────────

  Resolution mapResolution(String res) {
    switch (res) {
      case '240p':
        return Resolution.RESOLUTION_240;
      case '360p':
        return Resolution.RESOLUTION_360;
      case '480p':
        return Resolution.RESOLUTION_480;
      case '720p':
        return Resolution.RESOLUTION_720;
      case '1080p':
        return Resolution.RESOLUTION_1080;
      default:
        return Resolution.RESOLUTION_1080;
    }
  }

  VideoConfig buildVideoConfig() {
    final res = mapResolution(_resolution);
    final fps = _isNativeFps ? 30 : _customFps;
    if (_isNativeBitrate) {
      return VideoConfig.withDefaultBitrate(resolution: res, fps: fps);
    } else {
      return VideoConfig(bitrate: _customBitrate, resolution: res, fps: fps);
    }
  }

  Future<void> _applyVideoConfig() async {
    if (_controller == null) return;
    try {
      await _controller!.setVideoConfig(buildVideoConfig());
      debugPrint('[OnAir] VideoConfig applied (res=$_resolution, fps=${_isNativeFps ? "native" : _customFps}, bitrate=${_isNativeBitrate ? "native" : _customBitrate})');
    } catch (e) {
      debugPrint('[OnAir] setVideoConfig error: $e');
    }
  }

  void setResolution(String res) {
    _resolution = res;
    notifyListeners();
    _applyVideoConfig();
  }

  void setBitrateNative() {
    _isNativeBitrate = true;
    notifyListeners();
    _applyVideoConfig();
  }

  void setBitrateCustom(int br) {
    _isNativeBitrate = false;
    _customBitrate = br;
    notifyListeners();
    _applyVideoConfig();
  }

  void setFpsNative() {
    _isNativeFps = true;
    notifyListeners();
    _applyVideoConfig();
  }

  void setFpsCustom(int f) {
    _isNativeFps = false;
    _customFps = f;
    notifyListeners();
    _applyVideoConfig();
  }

  // ─── URL / StreamKey splitting ─────────────────────────

  static (String url, String key) splitUrlKey(String rawUrl, String rawKey) {
    final key = rawKey.trim();
    var url = rawUrl.trim();

    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    if (key.isNotEmpty) return (url, key);

    final schemeEnd = url.indexOf('://');
    if (schemeEnd < 0) return (url, 'stream');

    final afterScheme = url.substring(schemeEnd + 3);
    final firstSlash = afterScheme.indexOf('/');

    if (firstSlash < 0) return (url, 'stream');

    final pathPart = afterScheme.substring(firstSlash + 1);
    final lastSlash = pathPart.lastIndexOf('/');

    if (lastSlash < 0) {
      final base = url.substring(0, schemeEnd + 3 + firstSlash);
      return (base, pathPart);
    }

    final extractedKey = pathPart.substring(lastSlash + 1);
    final base = url.substring(0, url.length - extractedKey.length - 1);
    return (base, extractedKey);
  }

  // ─── TCP probe ──────────────────────────────────────────

  Future<bool> _probeServer(String url) async {
    try {
      String cleaned = url.trim();
      String host;
      int port;

      if (cleaned.startsWith('rtmps://')) {
        cleaned = cleaned.substring(8);
        port = 443;
      } else if (cleaned.startsWith('rtmp://')) {
        cleaned = cleaned.substring(7);
        port = 1935;
      } else {
        return false;
      }

      final pathStart = cleaned.indexOf('/');
      final hostPart =
          pathStart > 0 ? cleaned.substring(0, pathStart) : cleaned;
      final colonIdx = hostPart.lastIndexOf(':');
      if (colonIdx > 0) {
        host = hostPart.substring(0, colonIdx);
        port = int.tryParse(hostPart.substring(colonIdx + 1)) ?? port;
      } else {
        host = hostPart;
      }

      final socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return true;
    } catch (e) {
      debugPrint('[OnAir] TCP probe failed: $e');
      return false;
    }
  }

  // ─── Start streaming ──────────────────────────────────

  Future<void> startStreaming(ServerConfig server) async {
    if (_controller == null || _controllerBusy) return;

    _generation++;
    _activeServer = server;
    _status = StreamStatus.connecting;
    _errorMessage = '';
    userStopped = false;
    _reconnectAttempt = 0;
    _pendingReconnect = false;
    notifyListeners();

    ForegroundService.start();
    WakelockPlus.enable();
    _startWatchdog();

    await attemptConnect(server);
  }

  // ─── Core connect logic ─────────────────────────────────

  Future<void> attemptConnect(ServerConfig server) async {
    if (userStopped) return;

    // Capture generation at start — if it changes during this call,
    // a force-reconnect happened and we must bail out silently.
    final myGen = _generation;

    if (_controller == null || _controllerBusy) {
      debugPrint('[OnAir] attemptConnect deferred (ctrl=${_controller != null}, busy=$_controllerBusy)');
      _scheduleRetry(server);
      return;
    }

    // TCP probe
    final reachable = await _probeServer(server.url);
    if (userStopped || _generation != myGen) return;

    if (!reachable) {
      debugPrint('[OnAir] Server unreachable, will retry...');
      if (_generation == myGen) _scheduleReconnect();
      return;
    }

    // Split URL and stream key
    final (effectiveUrl, effectiveKey) = splitUrlKey(server.url, server.streamKey);
    debugPrint('[OnAir] Connecting to url=$effectiveUrl key=$effectiveKey');

    _controllerBusy = true;
    _pendingReconnect = false;

    try {
      // Clean-stop previous session (timeout prevents hang on dead TCP)
      _selfStopping = true;
      try {
        await _controller!.stopStreaming().timeout(const Duration(seconds: 2));
      } catch (_) {}

      // If generation changed while we were awaiting, bail out.
      if (_generation != myGen) return;
      _selfStopping = false;
      _pendingReconnect = false;

      if (userStopped) return;

      // Ensure preview is running (timeout prevents hang)
      try {
        await _controller!.startPreview().timeout(const Duration(seconds: 3));
      } catch (_) {}

      if (userStopped || _generation != myGen) return;

      // Connect (timeout prevents hang on dead server)
      try {
        await _controller!.startStreaming(
          streamKey: effectiveKey,
          url: effectiveUrl,
        ).timeout(const Duration(seconds: 5));
        if (_generation == myGen &&
            (_status == StreamStatus.connecting ||
             _status == StreamStatus.reconnecting)) {
          _onStreamingEstablished();
        }
      } catch (e) {
        debugPrint('[OnAir] startStreaming error: $e');
      }
    } catch (e) {
      debugPrint('[OnAir] attemptConnect unexpected error: $e');
    } finally {
      // Only reset state if WE still own it (same generation).
      if (_generation == myGen) {
        _controllerBusy = false;
        _selfStopping = false;
      }
    }

    // Post-checks — only if still our generation
    if (userStopped || _generation != myGen) return;

    if (_pendingReconnect ||
        (_status != StreamStatus.streaming && _activeServer != null)) {
      _pendingReconnect = false;
      _scheduleReconnect();
    }
  }

  void _scheduleRetry(ServerConfig server) {
    if (userStopped) return;
    _retryTimer?.cancel();
    final gen = _generation;
    _retryTimer = Timer(const Duration(milliseconds: 500), () {
      if (userStopped || _activeServer == null || _generation != gen) return;
      attemptConnect(server);
    });
  }

  void _onStreamingEstablished() {
    _reconnectAttempt = 0;
    _status = StreamStatus.streaming;
    _errorMessage = '';
    if (_duration == Duration.zero) {
      _startTimer();
    }
    notifyListeners();
  }

  // ─── Reconnect ─────────────────────────────────────────

  void _scheduleReconnect() {
    if (userStopped) return;
    _reconnectTimer?.cancel();
    _retryTimer?.cancel();
    _reconnectAttempt++;
    _status = StreamStatus.reconnecting;
    _errorMessage = 'Reconnecting... (attempt $_reconnectAttempt)';
    notifyListeners();

    final delayMs = _reconnectAttempt <= 1
        ? 0
        : (_reconnectAttempt.clamp(2, 6) - 1) * 1000;
    final gen = _generation;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (userStopped || _activeServer == null || _generation != gen) return;

      if (_reconnectAttempt > 0 &&
          _reconnectAttempt % 2 == 0 &&
          onControllerNeedsRecreate != null) {
        debugPrint('[OnAir] Requesting controller recreation (attempt $_reconnectAttempt)');
        _generation++;
        _controllerBusy = false;
        _selfStopping = false;
        _pendingReconnect = false;
        _recreationPending = true;
        onControllerNeedsRecreate!();
        return;
      }

      attemptConnect(_activeServer!);
    });
  }

  // ─── Watchdog ──────────────────────────────────────────

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (userStopped || _activeServer == null) {
        _watchdogTimer?.cancel();
        return;
      }

      final shouldBeActive = _status == StreamStatus.connecting ||
          _status == StreamStatus.streaming ||
          _status == StreamStatus.reconnecting;

      if (!shouldBeActive) {
        _watchdogTimer?.cancel();
        return;
      }

      // Skip if controller is being recreated — it's intentionally
      // null and no timers run during recreation.
      if (_recreationPending) return;

      if (!_controllerBusy &&
          _status != StreamStatus.streaming &&
          !_isTimerActive(_reconnectTimer) &&
          !_isTimerActive(_retryTimer)) {
        debugPrint('[OnAir] Watchdog: reconnect loop dead, restarting...');
        _scheduleReconnect();
      }
    });
  }

  bool _isTimerActive(Timer? timer) => timer != null && timer.isActive;

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  // ─── Stop streaming ───────────────────────────────────

  Future<void> stopStreaming() async {
    userStopped = true;
    _generation++;
    _reconnectTimer?.cancel();
    _retryTimer?.cancel();
    _networkDebounce?.cancel();
    _reconnectAttempt = 0;
    _pendingReconnect = false;
    _controllerBusy = false;
    _selfStopping = false;
    _stopWatchdog();

    _recreationPending = false;
    if (_controller != null) {
      try {
        await _controller!.stopStreaming().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    _status = StreamStatus.idle;
    _activeServer = null;
    _stopTimer();
    WakelockPlus.disable();
    ForegroundService.stop();
    notifyListeners();
  }

  // ─── Camera / Mic controls ──────────────────────────────

  Future<void> toggleCamera() async {
    if (_controller == null) return;
    try {
      await _controller!.switchCamera();
      _isFrontCamera = !_isFrontCamera;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setCameraPosition(bool front) async {
    if (_controller == null) return;
    try {
      await _controller!.setCameraPosition(
          front ? CameraPosition.front : CameraPosition.back);
      _isFrontCamera = front;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> toggleMute() async {
    if (_controller == null) return;
    _isMuted = !_isMuted;
    notifyListeners();
    try {
      await _controller!.setIsMuted(_isMuted);
      debugPrint('[OnAir] Mute: $_isMuted');
    } catch (_) {}
  }

  // ─── Native callbacks ─────────────────────────────────

  void onConnectionSuccess() {
    debugPrint('[OnAir] onConnectionSuccess');
    if (userStopped) return;
    if (_status == StreamStatus.connecting ||
        _status == StreamStatus.reconnecting) {
      _onStreamingEstablished();
    }
  }

  void onConnectionFailed(String reason) {
    debugPrint('[OnAir] onConnectionFailed: $reason');
    if (userStopped || _selfStopping) return;
    if (_inResumeGrace) {
      debugPrint('[OnAir] Ignoring onConnectionFailed during resume grace');
      return;
    }

    if (_controllerBusy) {
      _pendingReconnect = true;
      _status = StreamStatus.reconnecting;
      _errorMessage = reason.isEmpty
          ? 'Connection failed, retrying...'
          : '$reason - retrying...';
      notifyListeners();
      return;
    }

    _scheduleReconnect();
  }

  void onDisconnect() {
    debugPrint('[OnAir] onDisconnect (selfStop=$_selfStopping, userStop=$userStopped)');
    if (_selfStopping || userStopped) return;
    if (_inResumeGrace) {
      debugPrint('[OnAir] Ignoring onDisconnect during resume grace');
      return;
    }

    final wasActive = _status == StreamStatus.streaming ||
        _status == StreamStatus.connecting ||
        _status == StreamStatus.reconnecting;
    if (!wasActive) return;

    if (_controllerBusy) {
      _pendingReconnect = true;
      _status = StreamStatus.reconnecting;
      _errorMessage = 'Connection lost, retrying...';
      notifyListeners();
      return;
    }

    _scheduleReconnect();
  }

  // ─── Timer ──────────────────────────────────────────────

  void _startTimer() {
    _timer?.cancel();
    _duration = Duration.zero;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _duration += const Duration(seconds: 1);
      notifyListeners();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _duration = Duration.zero;
  }

  String get formattedDuration {
    final h = _duration.inHours.toString().padLeft(2, '0');
    final m = (_duration.inMinutes % 60).toString().padLeft(2, '0');
    final s = (_duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  void dispose() {
    userStopped = true;
    _generation++;
    _timer?.cancel();
    _reconnectTimer?.cancel();
    _retryTimer?.cancel();
    _stopWatchdog();
    _networkDebounce?.cancel();
    _connectivitySub?.cancel();
    _controller?.dispose();
    WakelockPlus.disable();
    ForegroundService.stop();
    super.dispose();
  }
}

import 'dart:async';
import 'package:apivideo_live_stream/apivideo_live_stream.dart';
import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/stream_config.dart';
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
  Timer? _connectTimeout;

  // Reconnect state
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  static const int _maxReconnectAttempts = 10;
  bool _userStopped = false;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _isFrontCamera = false;
  bool get isFrontCamera => _isFrontCamera;

  String _resolution = '1080p';
  String get resolution => _resolution;

  int _bitrate = 10000000;
  int get bitrate => _bitrate;

  int _fps = 30;
  int get fps => _fps;

  List<ServerConfig> _servers = [];
  List<ServerConfig> get servers => _servers;

  ServerConfig? _activeServer;
  ServerConfig? get activeServer => _activeServer;

  int get reconnectAttempt => _reconnectAttempt;

  LiveStreamProvider() {
    _loadServers();
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
    notifyListeners();
  }

  void setResolution(String res) {
    _resolution = res;
    notifyListeners();
  }

  void setBitrate(int br) {
    _bitrate = br;
    notifyListeners();
  }

  void setFps(int f) {
    _fps = f;
    notifyListeners();
  }

  Future<void> startStreaming(ServerConfig server) async {
    if (_controller == null) return;

    _activeServer = server;
    _status = StreamStatus.connecting;
    _errorMessage = '';
    _userStopped = false;
    _reconnectAttempt = 0;
    notifyListeners();

    _fireStartStreaming(server);
  }

  /// Non-blocking: fires startStreaming and relies on callbacks + timeout.
  void _fireStartStreaming(ServerConfig server) {
    // Cancel any previous timeout
    _connectTimeout?.cancel();

    // 5-second timeout - fully async, never blocks
    _connectTimeout = Timer(const Duration(seconds: 5), () {
      if (_status == StreamStatus.connecting ||
          _status == StreamStatus.reconnecting) {
        // Timeout reached - try to stop and attempt reconnect
        try {
          _controller?.stopStreaming();
        } catch (_) {}

        if (!_userStopped && _reconnectAttempt < _maxReconnectAttempts) {
          _scheduleReconnect();
        } else {
          _status = StreamStatus.error;
          _errorMessage =
              'Connection timed out after $_maxReconnectAttempts attempts.';
          _activeServer = null;
          _stopTimer();
          WakelockPlus.disable();
          notifyListeners();
        }
      }
    });

    // Fire-and-forget: don't await
    _controller!
        .startStreaming(
      streamKey: server.streamKey,
      url: server.url,
    )
        .catchError((e) {
      _connectTimeout?.cancel();
      if (!_userStopped && _reconnectAttempt < _maxReconnectAttempts) {
        _scheduleReconnect();
      } else {
        _status = StreamStatus.error;
        _errorMessage = e.toString();
        _activeServer = null;
        _stopTimer();
        WakelockPlus.disable();
        notifyListeners();
      }
    });
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    _status = StreamStatus.reconnecting;
    _errorMessage =
        'Reconnecting... (attempt $_reconnectAttempt/$_maxReconnectAttempts)';
    notifyListeners();

    // Backoff: 1s, 2s, 3s, 4s, 5s ... capped at 5s
    final delaySec = _reconnectAttempt.clamp(1, 5);
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (_userStopped || _activeServer == null) return;
      _fireStartStreaming(_activeServer!);
    });
  }

  Future<void> stopStreaming() async {
    _userStopped = true;
    _connectTimeout?.cancel();
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    if (_controller == null) return;

    try {
      await _controller!.stopStreaming();
    } catch (_) {}

    _status = StreamStatus.idle;
    _activeServer = null;
    _stopTimer();
    WakelockPlus.disable();
    notifyListeners();
  }

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
      await _controller!
          .setCameraPosition(front ? CameraPosition.front : CameraPosition.back);
      _isFrontCamera = front;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> toggleMute() async {
    if (_controller == null) return;
    _isMuted = !_isMuted;
    try {
      await _controller!.setIsMuted(_isMuted);
    } catch (_) {}
    notifyListeners();
  }

  void onConnectionSuccess() {
    _connectTimeout?.cancel();
    _reconnectTimer?.cancel();
    if (_status == StreamStatus.connecting ||
        _status == StreamStatus.reconnecting) {
      _reconnectAttempt = 0;
      _status = StreamStatus.streaming;
      _errorMessage = '';
      if (_duration == Duration.zero) {
        _startTimer();
      }
      WakelockPlus.enable();
      notifyListeners();
    }
  }

  void onConnectionFailed(String reason) {
    _connectTimeout?.cancel();

    // Auto-reconnect if user didn't manually stop
    if (!_userStopped &&
        _activeServer != null &&
        _reconnectAttempt < _maxReconnectAttempts) {
      _scheduleReconnect();
      return;
    }

    _status = StreamStatus.error;
    _errorMessage = reason.isEmpty ? 'Connection failed' : reason;
    _activeServer = null;
    _stopTimer();
    WakelockPlus.disable();
    notifyListeners();
  }

  void onDisconnect() {
    _connectTimeout?.cancel();

    // Auto-reconnect if was streaming and user didn't manually stop
    if (!_userStopped &&
        _activeServer != null &&
        (_status == StreamStatus.streaming ||
            _status == StreamStatus.connecting ||
            _status == StreamStatus.reconnecting) &&
        _reconnectAttempt < _maxReconnectAttempts) {
      // Keep timer running so duration continues
      _scheduleReconnect();
      return;
    }

    if (_status == StreamStatus.streaming ||
        _status == StreamStatus.connecting ||
        _status == StreamStatus.reconnecting) {
      _status = StreamStatus.idle;
      _activeServer = null;
      _stopTimer();
      WakelockPlus.disable();
      notifyListeners();
    }
  }

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
    _timer?.cancel();
    _connectTimeout?.cancel();
    _reconnectTimer?.cancel();
    _controller?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }
}

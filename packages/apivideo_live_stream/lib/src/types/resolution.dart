import 'dart:ui';

import 'package:json_annotation/json_annotation.dart';

/// Enumeration for camera resolution
/// Only 16/9 resolutions are supported.
enum Resolution {
  /// 426x240
  @JsonValue("240p")
  RESOLUTION_240(size: Size(426, 240)),

  /// 640x360
  @JsonValue("360p")
  RESOLUTION_360(size: Size(640, 360)),

  /// 854x480
  @JsonValue("480p")
  RESOLUTION_480(size: Size(854, 480)),

  /// 1280x720
  @JsonValue("720p")
  RESOLUTION_720(size: Size(1280, 720)),

  /// 1920x1080
  @JsonValue("1080p")
  RESOLUTION_1080(size: Size(1920, 1080)),

  /// 2560x1440
  @JsonValue("1440p")
  RESOLUTION_1440(size: Size(2560, 1440)),

  /// 3840x2160
  @JsonValue("2160p")
  RESOLUTION_2160(size: Size(3840, 2160));

  const Resolution({required this.size});

  final Size size;
}

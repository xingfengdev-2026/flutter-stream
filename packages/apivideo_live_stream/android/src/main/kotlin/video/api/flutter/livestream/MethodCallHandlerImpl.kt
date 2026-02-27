package video.api.flutter.livestream

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Size
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import video.api.flutter.livestream.utils.addTrailingSlashIfNeeded
import video.api.flutter.livestream.utils.toAudioConfig
import video.api.flutter.livestream.utils.toVideoConfig

class MethodCallHandlerImpl(
    private val context: Context,
    messenger: BinaryMessenger,
    private val permissionsManager: PermissionsManager,
    private val textureRegistry: TextureRegistry
) : MethodChannel.MethodCallHandler {
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL_NAME)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL_NAME)
    private var eventSink: EventChannel.EventSink? = null

    private var flutterView: FlutterLiveStreamView? = null

    fun startListening() {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink?.endOfStream()
                eventSink = null
            }
        })
    }

    fun stopListening() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> {
                try {
                    flutterView?.dispose()
                    flutterView = FlutterLiveStreamView(
                        context,
                        textureRegistry,
                        permissionsManager,
                        { sendConnected() },
                        { sendDisconnected() },
                        { sendConnectionFailed(it) },
                        { sendError(it) },
                        { sendVideoSizeChanged(it) }
                    )
                    result.success(mapOf("textureId" to flutterView!!.textureId))
                } catch (e: Exception) {
                    result.error("failed_to_create_live_stream", e.message, null)
                }
            }

            "dispose" -> {
                try {
                    flutterView?.dispose()
                } catch (e: Exception) {
                    android.util.Log.w("MethodCallHandler", "dispose error: ${e.message}")
                }
                flutterView = null
                result.success(null)
            }

            else -> {
                // Guard: all other methods require a live view
                val view = flutterView
                if (view == null) {
                    result.error("no_live_stream", "Live stream not created", null)
                    return
                }
                handleViewMethod(call, result, view)
            }
        }
    }

    private fun handleViewMethod(call: MethodCall, result: MethodChannel.Result, view: FlutterLiveStreamView) {
        when (call.method) {
            "setVideoConfig" -> {
                try {
                    @Suppress("UNCHECKED_CAST")
                    val videoConfig = (call.arguments as Map<String, Any>).toVideoConfig()
                    view.setVideoConfig(
                        videoConfig,
                        { result.success(null) },
                        {
                            result.error(
                                "failed_to_set_video_config",
                                it.message,
                                null
                            )
                        })
                } catch (e: Exception) {
                    result.error("failed_to_set_video_config", e.message, null)
                }
            }

            "setAudioConfig" -> {
                try {
                    @Suppress("UNCHECKED_CAST")
                    val audioConfig = (call.arguments as Map<String, Any>).toAudioConfig()
                    view.setAudioConfig(
                        audioConfig,
                        { result.success(null) },
                        {
                            result.error(
                                "failed_to_set_audio_config",
                                it.message,
                                null
                            )
                        })
                } catch (e: Exception) {
                    result.error("failed_to_set_audio_config", e.message, null)
                }
            }

            "startPreview" -> {
                try {
                    view.startPreview(
                        { result.success(null) },
                        {
                            result.error(
                                "failed_to_start_preview",
                                it.message,
                                null
                            )
                        })
                } catch (e: Exception) {
                    result.error("failed_to_start_preview", e.message, null)
                }
            }

            "stopPreview" -> {
                try { view.stopPreview() } catch (_: Exception) {}
                result.success(null)
            }

            "startStreaming" -> {
                val streamKey = call.argument<String>("streamKey")
                val url = call.argument<String>("url")
                when {
                    streamKey == null -> result.error(
                        "missing_stream_key", "Stream key is missing", null
                    )

                    streamKey.isEmpty() -> result.error(
                        "empty_stream_key", "Stream key is empty", null
                    )

                    url == null -> result.error(
                        "missing_rtmp_url",
                        "RTMP URL is missing",
                        null
                    )

                    url.isEmpty() -> result.error("empty_rtmp_url", "RTMP URL is empty", null)

                    else -> {
                        view.startStream(url.addTrailingSlashIfNeeded() + streamKey)
                        result.success(null)
                    }
                }
            }

            "stopStreaming" -> {
                try { view.stopStream() } catch (_: Exception) {}
                result.success(null)
            }

            "getIsStreaming" -> {
                try {
                    result.success(mapOf("isStreaming" to view.isStreaming))
                } catch (e: Exception) {
                    result.error("failed_to_get_is_streaming", e.message, null)
                }
            }

            "getCameraPosition" -> {
                try {
                    result.success(mapOf("position" to view.cameraPosition))
                } catch (e: Exception) {
                    result.error("failed_to_get_camera_position", e.message, null)
                }
            }

            "setCameraPosition" -> {
                val cameraPosition = try {
                    ((call.arguments as Map<*, *>)["position"] as String)
                } catch (e: Exception) {
                    result.error("invalid_parameter", "Invalid camera position", e)
                    return
                }
                try {
                    view.setCameraPosition(cameraPosition,
                        { result.success(null) },
                        {
                            result.error(
                                "failed_to_set_camera_position",
                                it.message,
                                null
                            )
                        })
                } catch (e: Exception) {
                    result.error("failed_to_set_camera_position", e.message, null)
                }
            }

            "getIsMuted" -> {
                try {
                    result.success(mapOf("isMuted" to view.isMuted))
                } catch (e: Exception) {
                    result.error("failed_to_get_is_muted", e.message, null)
                }
            }

            "setIsMuted" -> {
                val isMuted = try {
                    ((call.arguments as Map<*, *>)["isMuted"] as Boolean)
                } catch (e: Exception) {
                    result.error("invalid_parameter", "Invalid isMuted", e)
                    return
                }
                try {
                    view.isMuted = isMuted
                    result.success(null)
                } catch (e: Exception) {
                    result.error("failed_to_set_is_muted", e.message, null)
                }
            }

            "getVideoSize" -> {
                try {
                    val videoSize = view.videoConfig.resolution
                    result.success(
                        mapOf(
                            "width" to videoSize.width.toDouble(),
                            "height" to videoSize.height.toDouble()
                        )
                    )
                } catch (e: Exception) {
                    result.error("failed_to_get_video_size", e.message, null)
                }
            }

            "setVideoEnabled" -> {
                val enabled = try {
                    ((call.arguments as Map<*, *>)["enabled"] as Boolean)
                } catch (e: Exception) {
                    result.error("invalid_parameter", "Invalid enabled", e)
                    return
                }
                try {
                    view.setVideoEnabled(enabled,
                        { result.success(null) },
                        { result.error("failed_to_set_video_enabled", it.message, null) })
                } catch (e: Exception) {
                    result.error("failed_to_set_video_enabled", e.message, null)
                }
            }

            "getVideoEnabled" -> {
                try {
                    result.success(mapOf("enabled" to view.isVideoEnabled))
                } catch (e: Exception) {
                    result.error("failed_to_get_video_enabled", e.message, null)
                }
            }

            "setZoom" -> {
                val zoomRatio = try {
                    ((call.arguments as Map<*, *>)["zoomRatio"] as Number).toDouble()
                } catch (e: Exception) {
                    result.error("invalid_parameter", "Invalid zoomRatio", e)
                    return
                }
                try {
                    view.setZoom(zoomRatio)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("failed_to_set_zoom", e.message, null)
                }
            }

            "getMaxZoom" -> {
                try {
                    result.success(mapOf("maxZoom" to view.getMaxZoom()))
                } catch (e: Exception) {
                    result.error("failed_to_get_max_zoom", e.message, null)
                }
            }

            "getMinZoom" -> {
                try {
                    result.success(mapOf("minZoom" to view.getMinZoom()))
                } catch (e: Exception) {
                    result.error("failed_to_get_min_zoom", e.message, null)
                }
            }

            "setBitrate" -> {
                val bitrate = try {
                    ((call.arguments as Map<*, *>)["bitrate"] as Number).toInt()
                } catch (e: Exception) {
                    result.error("invalid_parameter", "Invalid bitrate", e)
                    return
                }
                try {
                    view.setBitrate(bitrate)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("failed_to_set_bitrate", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun sendEvent(type: String) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(mapOf("type" to type))
        }
    }

    private fun sendConnected() {
        sendEvent("connected")
    }

    private fun sendDisconnected() {
        sendEvent("disconnected")
    }

    private fun sendConnectionFailed(message: String) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(mapOf("type" to "connectionFailed", "message" to message))
        }
    }

    private fun sendError(error: Exception) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.error(error::class.java.name, error.message, error)
        }
    }

    private fun sendVideoSizeChanged(resolution: Size) {
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(
                mapOf(
                    "type" to "videoSizeChanged",
                    "width" to resolution.width.toDouble(),
                    "height" to resolution.height.toDouble() // Dart size fields are in double
                )
            )
        }
    }

    companion object {
        private const val METHOD_CHANNEL_NAME = "video.api.livestream/controller"
        private const val EVENT_CHANNEL_NAME = "video.api.livestream/events"
    }
}

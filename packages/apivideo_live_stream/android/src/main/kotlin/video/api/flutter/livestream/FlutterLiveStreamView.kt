package video.api.flutter.livestream

import android.Manifest
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry
import io.github.thibaultbee.streampack.data.AudioConfig
import io.github.thibaultbee.streampack.data.VideoConfig
import io.github.thibaultbee.streampack.error.StreamPackError
import io.github.thibaultbee.streampack.ext.rtmp.streamers.CameraRtmpLiveStreamer
import io.github.thibaultbee.streampack.listeners.OnConnectionListener
import io.github.thibaultbee.streampack.listeners.OnErrorListener
import io.github.thibaultbee.streampack.utils.backCameraList
import io.github.thibaultbee.streampack.utils.externalCameraList
import io.github.thibaultbee.streampack.utils.frontCameraList
import io.github.thibaultbee.streampack.utils.isBackCamera
import io.github.thibaultbee.streampack.utils.isExternalCamera
import io.github.thibaultbee.streampack.utils.isFrontCamera
import kotlinx.coroutines.runBlocking

class FlutterLiveStreamView(
    private val context: Context,
    textureRegistry: TextureRegistry,
    private val permissionsManager: PermissionsManager,
    private val onConnectionSucceeded: () -> Unit,
    private val onDisconnected: () -> Unit,
    private val onConnectionFailed: (String) -> Unit,
    private val onGenericError: (Exception) -> Unit,
    private val onVideoSizeChanged: (Size) -> Unit,
) :
    OnConnectionListener, OnErrorListener {
    private val flutterTexture = textureRegistry.createSurfaceTexture()
    val textureId: Long
        get() = flutterTexture.id()

    private val streamer = CameraRtmpLiveStreamer(
        context = context,
        initialOnConnectionListener = this,
        initialOnErrorListener = this
    )

    private var _isPreviewing = false
    private var _isStreaming = false
    val isStreaming: Boolean
        get() = _isStreaming


    private var _videoConfig: VideoConfig? = null
    val videoConfig: VideoConfig
        get() = _videoConfig!!

    fun setVideoConfig(
        videoConfig: VideoConfig,
        onSuccess: () -> Unit,
        onError: (Exception) -> Unit
    ) {
        if (isStreaming) {
            throw UnsupportedOperationException("You have to stop streaming first")
        }

        onVideoSizeChanged(videoConfig.resolution)

        val wasPreviewing = _isPreviewing
        if (wasPreviewing) {
            stopPreview()
        }
        streamer.configure(videoConfig)
        _videoConfig = videoConfig
        if (wasPreviewing) {
            startPreview(onSuccess, onError)
        } else {
            onSuccess()
        }
    }

    private var _audioConfig: AudioConfig? = null
    val audioConfig: AudioConfig
        get() = _audioConfig!!

    fun setAudioConfig(
        audioConfig: AudioConfig,
        onSuccess: () -> Unit,
        onError: (Exception) -> Unit
    ) {
        if (isStreaming) {
            throw UnsupportedOperationException("You have to stop streaming first")
        }

        permissionsManager.requestPermission(
            Manifest.permission.RECORD_AUDIO,
            onGranted = {
                try {
                    streamer.configure(audioConfig)
                    _audioConfig = audioConfig
                    onSuccess()
                } catch (e: Exception) {
                    onError(e)
                }
            },
            onShowPermissionRationale = { _ ->
                /**
                 * Require an AppCompat theme to use MaterialAlertDialogBuilder
                 *
                context.showDialog(
                R.string.permission_required,
                R.string.record_audio_permission_required_message,
                android.R.string.ok,
                onPositiveButtonClick = { onRequiredPermissionLastTime() }
                ) */
                onError(SecurityException("Missing permission Manifest.permission.RECORD_AUDIO"))
            },
            onDenied = {
                onError(SecurityException("Missing permission Manifest.permission.RECORD_AUDIO"))
            })
    }

    var isMuted: Boolean
        get() = streamer.settings.audio.isMuted
        set(value) {
            streamer.settings.audio.isMuted = value
        }

    val camera: String
        get() = streamer.camera

    fun setCamera(camera: String, onSuccess: () -> Unit, onError: (Exception) -> Unit) {
        permissionsManager.requestPermission(
            Manifest.permission.CAMERA,
            onGranted = {
                try {
                    streamer.camera = camera
                    onSuccess()
                } catch (e: Exception) {
                    onError(e)
                }
            },
            onShowPermissionRationale = { _ ->
                /**
                 * Require an AppCompat theme to use MaterialAlertDialogBuilder
                 *
                 * context.showDialog(
                R.string.permission_required,
                R.string.camera_permission_required_message,
                android.R.string.ok,
                onPositiveButtonClick = { onRequiredPermissionLastTime() }
                )*/
                onError(SecurityException("Missing permission Manifest.permission.CAMERA"))
            },
            onDenied = {
                onError(SecurityException("Missing permission Manifest.permission.CAMERA"))
            })
    }

    val cameraPosition: String
        get() = when {
            context.isFrontCamera(streamer.camera) -> "front"
            context.isBackCamera(streamer.camera) -> "back"
            context.isExternalCamera(streamer.camera) -> "other"
            else -> throw IllegalArgumentException("Invalid camera position for camera ${streamer.camera}")
        }

    fun setCameraPosition(position: String, onSuccess: () -> Unit, onError: (Exception) -> Unit) {
        val cameraList = when (position) {
            "front" -> context.frontCameraList
            "back" -> context.backCameraList
            "other" -> context.externalCameraList
            else -> throw IllegalArgumentException("Invalid camera position: $position")
        }
        setCamera(cameraList.first(), onSuccess, onError)
    }

    fun dispose() {
        stopStream()
        streamer.stopPreview()
        flutterTexture.release()
    }

    fun startStream(url: String) {
        runBlocking {
            streamer.connect(url)
            try {
                streamer.startStream()
                _isStreaming = true
            } catch (e: Exception) {
                streamer.disconnect()
                onLost("Failed to start stream: ${e.message}")
                throw e
            }
        }
    }

    fun stopStream() {
        val isConnected = streamer.isConnected
        runBlocking {
            streamer.stopStream()
            streamer.disconnect()
            if (isConnected) {
                onDisconnected()
            }
            _isStreaming = false
        }
    }

    fun startPreview(onSuccess: () -> Unit, onError: (Exception) -> Unit) {
        permissionsManager.requestPermission(
            Manifest.permission.CAMERA,
            onGranted = {
                if (_videoConfig == null) {
                    onError(IllegalStateException("Video has not been configured!"))
                } else {
                    try {
                        streamer.startPreview(getSurface(videoConfig.resolution))
                        _isPreviewing = true
                        onSuccess()
                    } catch (e: Exception) {
                        onError(e)
                    }
                }
            },
            onShowPermissionRationale = { _ ->
                /**
                 * Require an AppCompat theme to use MaterialAlertDialogBuilder
                 *
                 * context.showDialog(
                R.string.permission_required,
                R.string.camera_permission_required_message,
                android.R.string.ok,
                onPositiveButtonClick = { onRequiredPermissionLastTime() }
                )*/
                onError(SecurityException("Missing permission Manifest.permission.CAMERA"))
            },
            onDenied = {
                onError(SecurityException("Missing permission Manifest.permission.CAMERA"))
            })
    }

    fun stopPreview() {
        streamer.stopPreview()
        _isPreviewing = false
    }

    // ─── Video enable/disable (camera on/off while streaming) ──────
    //
    // We keep the camera running so the RTMP encoder continues to receive
    // frames (preventing stream interruption).  The Flutter side overlays
    // a black container when video is "off", so the phone shows black.

    private var _isVideoEnabled = true
    val isVideoEnabled: Boolean
        get() = _isVideoEnabled

    fun setVideoEnabled(enabled: Boolean, onSuccess: () -> Unit, onError: (Exception) -> Unit) {
        _isVideoEnabled = enabled
        // Don't stop/start preview — just track the flag.
        // Flutter UI handles displaying black overlay.
        onSuccess()
    }

    // ─── Camera list with labels ──────────────────────────────────
    //
    // Uses CameraManager directly (not StreamPack's extension) for
    // maximum compatibility.  Filters out depth / IR / non-standard
    // cameras via BACKWARD_COMPATIBLE capability check.

    fun getCameraList(position: String): List<Map<String, String>> {
        val facingValue = when (position) {
            "front" -> CameraCharacteristics.LENS_FACING_FRONT
            "back" -> CameraCharacteristics.LENS_FACING_BACK
            "other" -> CameraCharacteristics.LENS_FACING_EXTERNAL
            else -> throw IllegalArgumentException("Invalid camera position: $position")
        }

        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val result = mutableListOf<Map<String, String>>()

        for (cameraId in cameraManager.cameraIdList) {
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)

            // Must match requested facing direction
            val facing = characteristics.get(CameraCharacteristics.LENS_FACING) ?: continue
            if (facing != facingValue) continue

            // Must be a real camera (not depth sensor, IR, etc.)
            val capabilities = characteristics.get(
                CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES
            ) ?: intArrayOf()
            if (!capabilities.contains(
                    CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE
                )) continue

            val focalLengths = characteristics.get(
                CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS
            ) ?: floatArrayOf()

            val label = when {
                focalLengths.isEmpty() -> "Camera $cameraId"
                focalLengths[0] < 3.0f -> "Ultra Wide"
                focalLengths[0] < 6.0f -> "Wide"
                else -> "Telephoto"
            }
            result.add(mapOf("id" to cameraId, "label" to label))
        }

        // Sort by focal length: ultra-wide first, then wide, then telephoto
        return result.sortedBy { entry ->
            val cid = entry["id"] ?: return@sortedBy Float.MAX_VALUE
            val chars = cameraManager.getCameraCharacteristics(cid)
            val fl = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            fl?.firstOrNull() ?: Float.MAX_VALUE
        }
    }

    fun setCameraById(cameraId: String, onSuccess: () -> Unit, onError: (Exception) -> Unit) {
        permissionsManager.requestPermission(
            Manifest.permission.CAMERA,
            onGranted = {
                try {
                    streamer.camera = cameraId
                    onSuccess()
                } catch (e: Exception) {
                    onError(e)
                }
            },
            onShowPermissionRationale = { _ ->
                onError(SecurityException("Missing permission Manifest.permission.CAMERA"))
            },
            onDenied = {
                onError(SecurityException("Missing permission Manifest.permission.CAMERA"))
            })
    }

    // ─── Zoom ──────────────────────────────────────────────────────

    fun setZoom(zoomRatio: Double) {
        streamer.settings.camera.zoom.zoomRatio = zoomRatio.toFloat()
    }

    fun getMaxZoom(): Double {
        val range = streamer.settings.camera.zoom.availableRatioRange
        return range.upper.toDouble()
    }

    private fun getSurface(resolution: Size): Surface {
        val surfaceTexture = flutterTexture.surfaceTexture().apply {
            setDefaultBufferSize(
                resolution.width,
                resolution.height
            )
        }
        return Surface(surfaceTexture)
    }


    override fun onSuccess() {
        onConnectionSucceeded()
    }

    override fun onLost(message: String) {
        onDisconnected()
    }

    override fun onFailed(message: String) {
        onConnectionFailed(message)
    }

    override fun onError(error: StreamPackError) {
        _isStreaming = false
        onGenericError(error)
    }
}
package video.api.flutter.livestream

import android.Manifest
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.os.Build
import android.util.Log
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
import java.util.Locale
import kotlin.math.abs

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
        if (cameraList.isEmpty()) {
            throw IllegalStateException("No camera found for position: $position")
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

                // If video was disabled before streaming started, apply black screen
                if (!_isVideoEnabled) {
                    // Wait for encoder/CodecSurface to be fully initialized
                    // (setOutputSurface runs async on CodecSurface's executor)
                    var applied = false
                    for (attempt in 1..10) {
                        Thread.sleep(50)
                        try {
                            applyBlackScreen()
                            applied = true
                            break
                        } catch (e: Exception) {
                            Log.d(TAG, "Black screen attempt $attempt failed: ${e.message}")
                        }
                    }
                    if (applied) {
                        Log.d(TAG, "Video disabled at stream start — black frames active")
                    } else {
                        Log.w(TAG, "Could not apply black screen at stream start")
                    }
                }
            } catch (e: Exception) {
                streamer.disconnect()
                onLost("Failed to start stream: ${e.message}")
                throw e
            }
        }
    }

    fun stopStream() {
        clearVideoMuteState()
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
    // Keep preview/camera pipeline alive and force camera output to black
    // through Camera2 repeating settings. This avoids stream disconnects
    // caused by stopping preview during live encoding.

    private var _isVideoEnabled = true
    val isVideoEnabled: Boolean
        get() = _isVideoEnabled

    private var _videoMuteMode = VideoMuteMode.NONE

    private enum class VideoMuteMode {
        NONE,
        TEST_PATTERN,
        MIN_EXPOSURE
    }

    fun setVideoEnabled(enabled: Boolean, onSuccess: () -> Unit, onError: (Exception) -> Unit) {
        if (_isVideoEnabled == enabled) {
            onSuccess()
            return
        }
        _isVideoEnabled = enabled

        if (!_isStreaming) {
            Log.d(TAG, "Video ${if (enabled) "enabled" else "disabled"} (not streaming, flag only)")
            onSuccess()
            return
        }

        try {
            if (!enabled) {
                applyBlackScreen()
                Log.d(TAG, "Video disabled — black mode=$_videoMuteMode")
            } else {
                restoreNormalCamera()
                Log.d(TAG, "Video enabled — camera restored")
            }
            onSuccess()
        } catch (e: Exception) {
            Log.e(TAG, "setVideoEnabled($enabled) failed: ${e.message}", e)
            onError(e)
        }
    }

    /**
     * Switch video feed to black while keeping stream alive.
     */
    private fun applyBlackScreen() {
        clearVideoMuteState()
        if (!applyCamera2Blackout()) {
            throw IllegalStateException("Failed to apply black-screen capture mode")
        }
    }

    /**
     * Restore normal camera output from any black-screen mode.
     */
    private fun restoreNormalCamera() {
        restoreCamera2Blackout()
        _videoMuteMode = VideoMuteMode.NONE
    }

    /**
     * Clear any currently active black-screen mode without forcing preview restart.
     */
    private fun clearVideoMuteState() {
        when (_videoMuteMode) {
            VideoMuteMode.TEST_PATTERN, VideoMuteMode.MIN_EXPOSURE -> {
                try {
                    restoreCamera2Blackout()
                } catch (_: Exception) {}
            }
            VideoMuteMode.NONE -> {}
        }
        _videoMuteMode = VideoMuteMode.NONE
    }

    private fun getFieldWalkingUp(obj: Any, fieldName: String): Any? {
        var clazz: Class<*>? = obj.javaClass
        while (clazz != null) {
            try {
                val field = clazz.getDeclaredField(fieldName)
                field.isAccessible = true
                return field.get(obj)
            } catch (_: NoSuchFieldException) {
                clazz = clazz.superclass
            }
        }
        return null
    }

    /**
     * Keep camera running, force sensor output to black.
     */
    private fun applyCamera2Blackout(): Boolean {
        val controller = getCameraController() ?: return false

        return try {
            val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val chars = cameraManager.getCameraCharacteristics(streamer.camera)
            val patterns = chars.get(
                CameraCharacteristics.SENSOR_AVAILABLE_TEST_PATTERN_MODES
            ) ?: intArrayOf()

            if (patterns.contains(CameraMetadata.SENSOR_TEST_PATTERN_MODE_SOLID_COLOR)) {
                callSetRepeatingSetting(
                    controller,
                    CaptureRequest.SENSOR_TEST_PATTERN_MODE,
                    CameraMetadata.SENSOR_TEST_PATTERN_MODE_SOLID_COLOR
                )
                callSetRepeatingSetting(
                    controller,
                    CaptureRequest.SENSOR_TEST_PATTERN_DATA,
                    intArrayOf(0, 0, 0, 0)
                )
                _videoMuteMode = VideoMuteMode.TEST_PATTERN
                Log.d(TAG, "Black screen active via TEST_PATTERN")
                true
            } else {
                val exposureRange = chars.get(
                    CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE
                )
                val sensitivityRange = chars.get(
                    CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE
                )

                callSetRepeatingSetting(
                    controller,
                    CaptureRequest.CONTROL_AE_MODE,
                    CameraMetadata.CONTROL_AE_MODE_OFF
                )
                if (exposureRange != null) {
                    callSetRepeatingSetting(
                        controller,
                        CaptureRequest.SENSOR_EXPOSURE_TIME,
                        exposureRange.lower
                    )
                }
                if (sensitivityRange != null) {
                    callSetRepeatingSetting(
                        controller,
                        CaptureRequest.SENSOR_SENSITIVITY,
                        sensitivityRange.lower
                    )
                }
                _videoMuteMode = VideoMuteMode.MIN_EXPOSURE
                Log.d(TAG, "Black screen active via MIN_EXPOSURE")
                true
            }
        } catch (e: Exception) {
            Log.e(TAG, "Camera2 blackout failed: ${e.message}", e)
            _videoMuteMode = VideoMuteMode.NONE
            false
        }
    }

    private fun restoreCamera2Blackout() {
        val controller = getCameraController() ?: return

        try {
            when (_videoMuteMode) {
                VideoMuteMode.TEST_PATTERN -> {
                    callSetRepeatingSetting(
                        controller,
                        CaptureRequest.SENSOR_TEST_PATTERN_MODE,
                        CameraMetadata.SENSOR_TEST_PATTERN_MODE_OFF
                    )
                }

                VideoMuteMode.MIN_EXPOSURE -> {
                    callSetRepeatingSetting(
                        controller,
                        CaptureRequest.CONTROL_AE_MODE,
                        CameraMetadata.CONTROL_AE_MODE_ON
                    )
                }

                else -> {}
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to restore Camera2 blackout mode: ${e.message}")
        }
    }

    private fun getCameraController(): Any? {
        val cameraSource = getFieldWalkingUp(streamer, "cameraSource")
        if (cameraSource == null) {
            Log.w(TAG, "cameraSource field not found")
            return null
        }
        val controller = getFieldWalkingUp(cameraSource, "cameraController")
        if (controller == null) {
            Log.w(TAG, "cameraController field not found")
        }
        return controller
    }

    private fun <T : Any> callSetRepeatingSetting(
        controller: Any,
        key: CaptureRequest.Key<T>,
        value: T
    ) {
        val method = controller.javaClass.getMethod(
            "setRepeatingSetting",
            CaptureRequest.Key::class.java,
            Any::class.java
        )
        method.invoke(controller, key, value)
    }

    // ─── Camera list with labels ──────────────────────────────────

    fun getCameraList(position: String): List<Map<String, String>> {
        val facingValue = when (position) {
            "front" -> CameraCharacteristics.LENS_FACING_FRONT
            "back" -> CameraCharacteristics.LENS_FACING_BACK
            "other" -> CameraCharacteristics.LENS_FACING_EXTERNAL
            else -> throw IllegalArgumentException("Invalid camera position: $position")
        }

        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val allIds = cameraManager.cameraIdList
        Log.d(TAG, "getCameraList($position): all camera IDs = ${allIds.toList()}")

        val cameras = mutableListOf<Map<String, String>>()

        for (cameraId in allIds) {
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)

            val facing = characteristics.get(CameraCharacteristics.LENS_FACING) ?: continue
            if (facing != facingValue) continue

            val capabilities = characteristics.get(
                CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES
            ) ?: intArrayOf()

            // Only skip cameras that are exclusively depth/ToF sensors
            val isDepthOnly = capabilities.isNotEmpty() &&
                    capabilities.all {
                        it == CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT
                    }
            if (isDepthOnly) {
                Log.d(TAG, "  Camera $cameraId: depth-only sensor — skip")
                continue
            }

            val focalLength = firstFocalLength(characteristics)

            var physicalIds: Set<String> = emptySet()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                physicalIds = characteristics.physicalCameraIds
            }

            Log.d(TAG, "  Camera $cameraId: facing=$facing, " +
                    "focal=${focalLength ?: -1f}, capabilities=${capabilities.toList()}, " +
                    "physicalCameras=$physicalIds")

            val label = buildCameraLabel(cameraId, focalLength)
            cameras.add(mapOf("id" to cameraId, "label" to label))
        }

        // If only one logical back camera is openable, synthesize selectable
        // lens entries from physical sub-cameras using real focal lengths.
        if (position == "back" && cameras.size <= 1) {
            val logicalId = cameras.firstOrNull()?.get("id")
            if (logicalId != null) {
                val virtualLenses = buildVirtualBackLenses(cameraManager, logicalId)
                if (virtualLenses.size > 1) {
                    Log.d(TAG, "Using virtual back lenses: $virtualLenses")
                    return virtualLenses.sortedBy { entry ->
                        val id = entry["id"] ?: return@sortedBy Float.MAX_VALUE
                        parseVirtualLensId(id)?.second ?: Float.MAX_VALUE
                    }
                }
            }
        }

        Log.d(TAG, "getCameraList($position) result: $cameras")

        return cameras.sortedBy { entry ->
            val cid = entry["id"] ?: return@sortedBy Float.MAX_VALUE
            try {
                val chars = cameraManager.getCameraCharacteristics(cid)
                firstFocalLength(chars) ?: Float.MAX_VALUE
            } catch (_: Exception) {
                Float.MAX_VALUE
            }
        }
    }

    private fun firstFocalLength(characteristics: CameraCharacteristics): Float? {
        val focal = characteristics.get(
            CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS
        ) ?: return null
        return focal.firstOrNull()
    }

    private fun buildVirtualBackLenses(
        cameraManager: CameraManager,
        logicalId: String
    ): List<Map<String, String>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return emptyList()

        return try {
            val logicalChars = cameraManager.getCameraCharacteristics(logicalId)
            val physicalIds = logicalChars.physicalCameraIds
            if (physicalIds.size <= 1) return emptyList()

            val physicalLenses = mutableListOf<Triple<String, Float, String>>()
            for (pid in physicalIds) {
                try {
                    val pChars = cameraManager.getCameraCharacteristics(pid)
                    val pCaps = pChars.get(
                        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES
                    ) ?: intArrayOf()
                    val pIsDepthOnly = pCaps.isNotEmpty() && pCaps.all {
                        it == CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT
                    }
                    if (pIsDepthOnly) continue

                    val pFocal = firstFocalLength(pChars) ?: continue
                    val pLabel = buildCameraLabel(pid, pFocal)
                    physicalLenses.add(Triple(pid, pFocal, pLabel))
                } catch (e: Exception) {
                    Log.w(TAG, "  Physical $pid unavailable: ${e.message}")
                }
            }

            if (physicalLenses.size <= 1) return emptyList()

            val logicalFocal = firstFocalLength(logicalChars)
            val referenceFocal = logicalFocal
                ?: physicalLenses.minByOrNull { abs(it.second - 4.5f) }?.second
                ?: physicalLenses.first().second

            val minZoom = try {
                getMinZoom().toFloat()
            } catch (_: Exception) {
                1.0f
            }
            val maxZoom = try {
                getMaxZoom().toFloat()
            } catch (_: Exception) {
                10.0f
            }

            val unique = LinkedHashMap<String, Map<String, String>>()
            for ((_, focal, label) in physicalLenses.sortedBy { it.second }) {
                var zoomRatio = focal / referenceFocal
                if (!zoomRatio.isFinite() || zoomRatio <= 0f) {
                    zoomRatio = 1.0f
                }
                zoomRatio = zoomRatio.coerceIn(minZoom, maxZoom)

                val ratioId = String.format(Locale.US, "%.3f", zoomRatio)
                val ratioLabel = formatZoomLabel(zoomRatio)
                val id = "$VIRTUAL_LENS_PREFIX$logicalId:$ratioId"
                val display = "$label ($ratioLabel)"
                unique[id] = mapOf("id" to id, "label" to display)
            }
            unique.values.toList()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to build virtual back lenses: ${e.message}")
            emptyList()
        }
    }

    private fun buildCameraLabel(
        cameraId: String,
        focalLength: Float?
    ): String {
        if (focalLength == null) return "Camera $cameraId"
        val fl = focalLength
        val label = when {
            fl < 3.0f -> "Ultra Wide"
            fl < 6.0f -> "Wide"
            fl < 10.0f -> "Telephoto"
            else -> "Super Telephoto"
        }
        return "$label (${String.format(Locale.US, "%.1f", fl)}mm)"
    }

    private fun formatZoomLabel(zoomRatio: Float): String {
        val text = String.format(Locale.US, "%.2f", zoomRatio)
            .trimEnd('0')
            .trimEnd('.')
        return "${text}x"
    }

    private fun parseVirtualLensId(cameraId: String): Pair<String, Float>? {
        if (!cameraId.startsWith(VIRTUAL_LENS_PREFIX)) return null
        val payload = cameraId.removePrefix(VIRTUAL_LENS_PREFIX)
        val sep = payload.lastIndexOf(':')
        if (sep <= 0 || sep >= payload.length - 1) return null
        val logicalId = payload.substring(0, sep)
        val zoomRatio = payload.substring(sep + 1).toFloatOrNull() ?: return null
        return logicalId to zoomRatio
    }

    fun setCameraById(cameraId: String, onSuccess: () -> Unit, onError: (Exception) -> Unit) {
        permissionsManager.requestPermission(
            Manifest.permission.CAMERA,
            onGranted = {
                try {
                    val wasMuted = !_isVideoEnabled && _isStreaming
                    if (wasMuted) {
                        clearVideoMuteState()
                    }

                    val virtualLens = parseVirtualLensId(cameraId)
                    if (virtualLens != null) {
                        val (logicalId, zoomRatio) = virtualLens
                        if (streamer.camera != logicalId) {
                            streamer.camera = logicalId
                        }
                        setZoom(zoomRatio.toDouble())
                    } else {
                        streamer.camera = cameraId
                    }

                    if (wasMuted) {
                        // Re-apply black screen mode for the newly selected camera.
                        applyBlackScreen()
                    }

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
        return streamer.settings.camera.zoom.availableRatioRange.upper.toDouble()
    }

    fun getMinZoom(): Double {
        return streamer.settings.camera.zoom.availableRatioRange.lower.toDouble()
    }

    // ─── Dynamic bitrate ───────────────────────────────────────────

    fun setBitrate(bitrate: Int) {
        Log.d(TAG, "setBitrate($bitrate)")
        streamer.settings.video.bitrate = bitrate
    }

    private fun getSurface(resolution: Size): Surface {
        val surfaceTexture = flutterTexture.surfaceTexture().apply {
            setDefaultBufferSize(resolution.width, resolution.height)
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
        clearVideoMuteState()
        onGenericError(error)
    }

    companion object {
        private const val TAG = "FlutterLiveStreamView"
        private const val VIRTUAL_LENS_PREFIX = "virtual:"
    }
}

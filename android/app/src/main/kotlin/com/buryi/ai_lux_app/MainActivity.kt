package com.buryi.ai_lux_app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.hardware.camera2.params.RggbChannelVector
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import android.view.TextureView
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import java.io.File
import java.io.FileOutputStream

private const val TAG = "Camera2Service"
private const val CHANNEL = "com.buryi.ai_lux_app/camera2"
private const val VIEW_TYPE = "camera2_preview"

// Training protocol settings — must match dataset collection exactly
private const val TARGET_ISO = 50
private const val TARGET_EXPOSURE_NS = 20_000_000L  // 1/50s in nanoseconds

// 4000K white balance channel gains derived from actual training JPEG channel
// ratios on white paper (mean across 20 images): R/G=1.163, B/G=1.050.
// These reproduce the same channel balance Samsung PRO camera applied at 4000K.
private const val WB_R  = 1.1630f
private const val WB_GR = 1.0000f
private const val WB_GB = 1.0000f
private const val WB_B  = 1.0502f

// ── PlatformView that wraps a TextureView for the camera preview ─────────────

class Camera2PreviewView(
    context: Context,
    service: Camera2Service,
) : PlatformView {
    private val textureView = TextureView(context)
    init { service.attachTextureView(textureView) }
    override fun getView() = textureView
    override fun dispose() {}
}

class Camera2PreviewFactory(
    private val service: Camera2Service,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        Camera2PreviewView(context, service)
}

// ── Camera2Service ────────────────────────────────────────────────────────────

class Camera2Service(private val activity: FlutterActivity) {

    private val manager by lazy {
        activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    }

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    private var textureView: TextureView? = null
    private var pendingResult: MethodChannel.Result? = null

    fun startBackgroundThread() {
        if (backgroundThread != null) return  // already running
        backgroundThread = HandlerThread("Camera2BG").also { it.start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    /// Reopens the camera if it was closed (e.g. after the gallery picker
    /// sent the app to background and the lifecycle handler disposed it)
    /// while the preview TextureView is still alive. Without this, the
    /// camera stays dead after returning from an upload.
    fun reopenIfNeeded() {
        if (cameraDevice != null) return
        val tv = textureView ?: return
        if (tv.isAvailable) {
            openCamera(tv.width, tv.height)
        } else {
            tv.surfaceTextureListener = surfaceListener
        }
    }

    fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try { backgroundThread?.join() } catch (_: InterruptedException) {}
        backgroundThread = null
        backgroundHandler = null
    }

    fun attachTextureView(tv: TextureView) {
        textureView = tv
        if (tv.isAvailable) openCamera(tv.width, tv.height)
        else tv.surfaceTextureListener = surfaceListener
    }

    fun closeCamera() {
        captureSession?.close(); captureSession = null
        cameraDevice?.close(); cameraDevice = null
        imageReader?.close(); imageReader = null
    }

    private val surfaceListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) {
            openCamera(w, h)
        }
        override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) {}
        override fun onSurfaceTextureDestroyed(st: SurfaceTexture) = true
        override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
    }

    private fun openCamera(width: Int, height: Int) {
        if (ActivityCompat.checkSelfPermission(activity, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "Camera permission not granted"); return
        }
        val cameraId = manager.cameraIdList[0]
        val chars = manager.getCameraCharacteristics(cameraId)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
        val largest = map.getOutputSizes(ImageFormat.JPEG)
            .maxByOrNull { it.width.toLong() * it.height }!!

        imageReader = ImageReader.newInstance(largest.width, largest.height, ImageFormat.JPEG, 2)
            .apply {
                setOnImageAvailableListener({ reader ->
                    val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                    val buf = image.planes[0].buffer
                    val bytes = ByteArray(buf.remaining()).also { buf.get(it) }
                    image.close()
                    saveAndReturn(bytes)
                }, backgroundHandler)
            }

        manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                createPreviewSession()
            }
            override fun onDisconnected(camera: CameraDevice) { camera.close() }
            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                Log.e(TAG, "Camera error: $error")
            }
        }, backgroundHandler)
    }

    /// Largest HAL-supported SurfaceTexture size <= 1920x1440. Never the
    /// full sensor resolution: creating a 4080x3060 preview stream makes
    /// the HAL throw "Function not implemented", which killed the app
    /// when the view size was unsettled after the gallery picker.
    private fun safePreviewSize(): android.util.Size {
        return try {
            val chars = manager.getCameraCharacteristics(
                manager.cameraIdList[0])
            val sizes = chars.get(
                    CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
                .getOutputSizes(SurfaceTexture::class.java)
            sizes.filter { it.width <= 1920 && it.height <= 1440 }
                .maxByOrNull { it.width.toLong() * it.height }
                ?: sizes.minByOrNull { it.width.toLong() * it.height }!!
        } catch (e: Exception) {
            android.util.Size(1280, 960)
        }
    }

    private fun createPreviewSession() {
        val tv = textureView ?: return
        val st = tv.surfaceTexture ?: return
        val ps = safePreviewSize()
        st.setDefaultBufferSize(ps.width, ps.height)
        val previewSurface = Surface(st)
        try {

        cameraDevice!!.createCaptureSession(
            listOf(previewSurface, imageReader!!.surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    // RACE GUARD: this callback can fire after closeCamera()
                    // (e.g. user opened the gallery picker mid-configuration).
                    // Starting a repeating request on a closed device throws
                    // IllegalStateException and kills the whole app.
                    val device = cameraDevice
                    if (device == null) {
                        try { session.close() } catch (_: Exception) {}
                        return
                    }
                    captureSession = session
                    try {
                        val req = device
                            .createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                            .apply {
                                addTarget(previewSurface)
                                applyTrainingSettings(this)
                            }.build()
                        session.setRepeatingRequest(req, null, backgroundHandler)
                    } catch (e: Exception) {
                        Log.e(TAG, "Preview start failed (camera closed?): $e")
                    }
                }
                override fun onConfigureFailed(session: CameraCaptureSession) {
                    Log.e(TAG, "Preview session configuration failed")
                }
            }, backgroundHandler
        )
        } catch (e: Exception) {
            // Transient failures happen right after the picker returns;
            // log and retry once instead of dying on the camera thread.
            Log.e(TAG, "createCaptureSession failed: $e — retrying once")
            backgroundHandler?.postDelayed({
                try { createPreviewSession() } catch (e2: Exception) {
                    Log.e(TAG, "Preview retry failed: $e2")
                }
            }, 400)
        }
    }

    private fun applyTrainingSettings(b: CaptureRequest.Builder) {
        // Exposure: disable AE, set ISO 50 + 1/50s
        b.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
        b.set(CaptureRequest.SENSOR_SENSITIVITY, TARGET_ISO)
        b.set(CaptureRequest.SENSOR_EXPOSURE_TIME, TARGET_EXPOSURE_NS)
        // White balance: disable AWB, apply gains computed from training data
        // channel ratios on white paper (R/G=1.163, B/G=1.050) to reproduce
        // exactly the Samsung PRO 4000K color rendering used during data collection.
        b.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_OFF)
        b.set(CaptureRequest.COLOR_CORRECTION_MODE,
            CaptureRequest.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX)
        b.set(CaptureRequest.COLOR_CORRECTION_GAINS,
            RggbChannelVector(WB_R, WB_GR, WB_GB, WB_B))
        // Focus: manual, infinity
        b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
        b.set(CaptureRequest.LENS_FOCUS_DISTANCE, 0.0f)
        // Flash: off
        b.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
    }

    fun captureStill(result: MethodChannel.Result) {
        val session = captureSession
        val device = cameraDevice
        if (session == null || device == null) {
            result.error("NOT_READY", "Camera not initialized", null); return
        }
        pendingResult = result
        val req = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
            .apply {
                addTarget(imageReader!!.surface)
                applyTrainingSettings(this)
                // CRITICAL: without JPEG_ORIENTATION the HAL writes the JPEG
                // at sensor-native (landscape) orientation with no EXIF tag,
                // so the Dart pipeline's bakeOrientation() does nothing and
                // every ROI lands in the wrong place. This tells the HAL to
                // rotate pixels (or set EXIF) so the image decodes portrait.
                set(CaptureRequest.JPEG_ORIENTATION, computeJpegOrientation())
            }.build()
        session.capture(req, object : CameraCaptureSession.CaptureCallback() {
            override fun onCaptureFailed(
                s: CameraCaptureSession, r: CaptureRequest, f: CaptureFailure) {
                activity.runOnUiThread {
                    pendingResult?.error("CAPTURE_FAILED", "Reason: ${f.reason}", null)
                    pendingResult = null
                }
            }
        }, backgroundHandler)
    }

    private fun saveAndReturn(bytes: ByteArray) {
        val file = File(activity.filesDir, "CAP_${System.currentTimeMillis()}.jpg")
        FileOutputStream(file).use { it.write(bytes) }
        Log.d(TAG, "Saved: ${file.absolutePath}")
        activity.runOnUiThread {
            pendingResult?.success(file.absolutePath)
            pendingResult = null
        }
    }

    /// Standard back-camera JPEG orientation: sensor orientation compensated
    /// by current display rotation. For this portrait-locked app on the A16
    /// (sensor orientation 90) this returns 90.
    private fun computeJpegOrientation(): Int {
        val cameraId = manager.cameraIdList[0]
        val chars = manager.getCameraCharacteristics(cameraId)
        val sensor = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val rotation = if (android.os.Build.VERSION.SDK_INT >= 30) {
            activity.display?.rotation ?: Surface.ROTATION_0
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.rotation
        }
        val displayDeg = when (rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        return (sensor - displayDeg + 360) % 360
    }

    fun getSettingsInfo(): Map<String, Any?> {
        val cameraId = manager.cameraIdList[0]
        val chars = manager.getCameraCharacteristics(cameraId)
        val isoRange = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val expRange = chars.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        return mapOf(
            "iso_target" to TARGET_ISO,
            "exposure_target_ns" to TARGET_EXPOSURE_NS,
            "iso_min" to isoRange?.lower,
            "iso_max" to isoRange?.upper,
            "iso_50_supported" to ((isoRange?.lower ?: 999) <= 50),
            "wb_r" to WB_R,
            "wb_b" to WB_B,
        )
    }
}

// ── MainActivity ──────────────────────────────────────────────────────────────

class MainActivity : FlutterActivity() {
    private lateinit var camera2: Camera2Service
    private var pendingImport: MethodChannel.Result? = null
    private val importReq = 7710

    private fun customModelsDir(): File =
        File(filesDir, "custom_models").apply { mkdirs() }

    private fun displayNameOf(uri: Uri): String {
        var name = "imported_${System.currentTimeMillis()}"
        val c: Cursor? = contentResolver.query(uri, null, null, null, null)
        c?.use {
            val idx = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && it.moveToFirst()) name = it.getString(idx)
        }
        return name
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != importReq) return
        val res = pendingImport; pendingImport = null
        if (resultCode != RESULT_OK || data == null) {
            res?.success(emptyList<String>()); return
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { cd -> for (i in 0 until cd.itemCount) uris.add(cd.getItemAt(i).uri) }
        data.data?.let { uris.add(it) }
        val copied = mutableListOf<String>()
        for (uri in uris) {
            try {
                val name = displayNameOf(uri)
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(File(customModelsDir(), name)).use { input.copyTo(it) }
                }
                copied.add(name)
            } catch (e: Exception) {
                Log.e(TAG, "Import failed for $uri: $e")
            }
        }
        res?.success(copied)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        camera2 = Camera2Service(this)

        flutterEngine.platformViewsController.registry
            .registerViewFactory(VIEW_TYPE, Camera2PreviewFactory(camera2))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "init"        -> { camera2.startBackgroundThread()
                                       camera2.reopenIfNeeded()
                                       result.success(camera2.getSettingsInfo()) }
                    "capture"     -> camera2.captureStill(result)
                    "getSettings" -> result.success(camera2.getSettingsInfo())
                    "deviceInfo"  -> result.success(mapOf(
                                       "manufacturer" to Build.MANUFACTURER,
                                       "model" to Build.MODEL))
                    "customModelsDir" -> result.success(customModelsDir().absolutePath)
                    "importModels" -> {
                        pendingImport = result
                        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        }
                        startActivityForResult(i, importReq)
                    }
                    "dispose"     -> { camera2.closeCamera()
                                       camera2.stopBackgroundThread()
                                       result.success(null) }
                    else          -> result.notImplemented()
                }
            }
    }

    override fun onResume()  { super.onResume();  camera2.startBackgroundThread(); camera2.reopenIfNeeded() }
    override fun onPause()   { camera2.stopBackgroundThread(); super.onPause() }
    override fun onDestroy() { camera2.closeCamera(); super.onDestroy() }
}

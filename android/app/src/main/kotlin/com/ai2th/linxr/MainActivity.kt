package com.ai2th.linxr

import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val TAG = "LinxrMainActivity"
    private val CHANNEL = "com.ai2th.linxr/vm"
    private val vmManager get() = (applicationContext as AlpineApp).vmManager
    private val executor = Executors.newSingleThreadExecutor()

    private val requestNotificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        Log.i(TAG, "POST_NOTIFICATIONS granted=$granted")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED) {
                requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVm" -> executor.execute {
                        try {
                            startVmService()
                            vmManager.startVm()
                            if (!isFinishing) runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("VM_START_ERROR", e.message, null) }
                        }
                    }

                    "stopVm" -> executor.execute {
                        try {
                            vmManager.stopVm()
                            stopVmService()
                            if (!isFinishing) runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("VM_STOP_ERROR", e.message, null) }
                        }
                    }

                    "getVmStatus" -> executor.execute {
                        try {
                            val status = vmManager.getStatus()
                            if (!isFinishing) runOnUiThread { result.success(status) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.success("unknown") }
                        }
                    }

                    "getDeviceInfo" -> {
                        try {
                            result.success(vmManager.getDeviceInfo())
                        } catch (e: Exception) {
                            result.success(mapOf("cores" to 4, "totalRamMb" to 4096, "freeStorageGb" to 32))
                        }
                    }

                    "resetStorage" -> executor.execute {
                        try {
                            vmManager.stopVm()
                            stopVmService()
                            vmManager.resetStorage()
                            if (!isFinishing) runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("RESET_ERROR", e.message, null) }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        executor.shutdownNow()
        executor.awaitTermination(10, TimeUnit.SECONDS)
        super.onDestroy()
    }

    private fun startVmService() {
        val intent = Intent(this, VmService::class.java)
        startForegroundService(intent)
    }

    private fun stopVmService() {
        val intent = Intent(this, VmService::class.java)
        stopService(intent)
    }
}

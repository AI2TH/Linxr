package com.ai2th.linxr

import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "LinxrMainActivity"
    }
    private val CHANNEL = "com.ai2th.linxr/vm"
    private val vmManager get() = (applicationContext as AlpineApp).vmManager
    private val executor = Executors.newSingleThreadExecutor()

    private val REQUEST_POST_NOTIFICATIONS = 1001
    private val REQUEST_STORAGE = 1002

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQUEST_POST_NOTIFICATIONS
                )
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) !=
                PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                    REQUEST_STORAGE
                )
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            REQUEST_POST_NOTIFICATIONS -> {
                val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                Log.i(TAG, "POST_NOTIFICATIONS granted=$granted")
            }
            REQUEST_STORAGE -> {
                val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                Log.i(TAG, "READ_EXTERNAL_STORAGE granted=$granted")
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

                    "checkHealth" -> executor.execute {
                        try {
                            val healthy = vmManager.checkHealth()
                            if (!isFinishing) runOnUiThread { result.success(healthy) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.success(false) }
                        }
                    }

                    "startContainer" -> executor.execute {
                        try {
                            val image = call.argument<String>("image")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_START_ERROR", "image required", null)
                                }
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_START_ERROR", "name required", null)
                                }
                            val cmd = call.argument<List<String>>("cmd") ?: emptyList()
                            vmManager.startContainer(image, name, cmd)
                            if (!isFinishing) runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_START_ERROR", e.message, null) }
                        }
                    }

                    "stopContainer" -> executor.execute {
                        try {
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_STOP_ERROR", "name required", null)
                                }
                            vmManager.stopContainer(name)
                            if (!isFinishing) runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_STOP_ERROR", e.message, null) }
                        }
                    }

                    "listContainers" -> executor.execute {
                        try {
                            val containers = vmManager.listContainers()
                            if (!isFinishing) runOnUiThread { result.success(containers) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_LIST_ERROR", e.message, null) }
                        }
                    }

                    "getLogs" -> executor.execute {
                        try {
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("LOGS_ERROR", "name required", null)
                                }
                            val tail = call.argument<Int>("tail") ?: 100
                            val logs = vmManager.getLogs(name, tail)
                            if (!isFinishing) runOnUiThread { result.success(logs) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("LOGS_ERROR", e.message, null) }
                        }
                    }

                    "vmExec" -> executor.execute {
                        try {
                            val cmd = call.argument<String>("cmd")
                                ?: return@execute runOnUiThread {
                                    result.error("VM_EXEC_ERROR", "cmd required", null)
                                }
                            val output = vmManager.vmExec(cmd)
                            if (!isFinishing) runOnUiThread { result.success(output) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("VM_EXEC_ERROR", e.message, null) }
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

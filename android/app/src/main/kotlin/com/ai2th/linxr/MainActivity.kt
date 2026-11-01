package com.ai2th.linxr

import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.app.Activity
import android.net.Uri
import android.provider.DocumentsContract
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
    private val executor = Executors.newCachedThreadPool()

    private val REQUEST_PERMISSIONS = 1001
    private val REQUEST_PICK_FOLDER = 1003
    private var pendingFolderResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val permsToRequest = mutableListOf<String>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED) {
                permsToRequest.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        if (Build.VERSION.SDK_INT in Build.VERSION_CODES.M until Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) !=
                PackageManager.PERMISSION_GRANTED) {
                permsToRequest.add(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
        }

        if (permsToRequest.isNotEmpty()) {
            ActivityCompat.requestPermissions(
                this,
                permsToRequest.toTypedArray(),
                REQUEST_PERMISSIONS
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_PERMISSIONS) {
            for (i in permissions.indices) {
                val granted = grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED
                Log.i(TAG, "Permission ${permissions[i]} granted=$granted")
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
                            val ports = call.argument<List<Map<String, Any>>>("ports") ?: emptyList()
                            val env = call.argument<List<Map<String, String>>>("env") ?: emptyList()
                            val network = call.argument<String>("network") ?: "host"
                            vmManager.startContainer(image, name, cmd, ports, env, network)
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

                    "startExistingContainer" -> executor.execute {
                        try {
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_START_ERROR", "name required", null)
                                }
                            vmManager.startExistingContainer(name)
                            if (!isFinishing) runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_START_ERROR", e.message, null) }
                        }
                    }

                    "restartContainer" -> executor.execute {
                        try {
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_RESTART_ERROR", "name required", null)
                                }
                            vmManager.restartContainer(name)
                            if (!isFinishing) runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_RESTART_ERROR", e.message, null) }
                        }
                    }

                    "deleteContainer" -> executor.execute {
                        try {
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_DELETE_ERROR", "name required", null)
                                }
                            vmManager.deleteContainer(name)
                            if (!isFinishing) runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_DELETE_ERROR", e.message, null) }
                        }
                    }

                    "updateContainer" -> executor.execute {
                        try {
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_UPDATE_ERROR", "name required", null)
                                }
                            val restartPolicy = call.argument<String>("restartPolicy")
                            val memoryMb = (call.argument<Number>("memoryMb"))?.toLong()
                            val cpus = call.argument<Double>("cpus")
                            vmManager.updateContainer(name, restartPolicy, memoryMb, cpus)
                            if (!isFinishing) runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_UPDATE_ERROR", e.message, null) }
                        }
                    }

                    "inspectContainer" -> executor.execute {
                        try {
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_INSPECT_ERROR", "name required", null)
                                }
                            val info = vmManager.inspectContainer(name)
                            if (!isFinishing) runOnUiThread { result.success(info) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_INSPECT_ERROR", e.message, null) }
                        }
                    }

                    "exportContainer" -> executor.execute {
                        try {
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_EXPORT_ERROR", "name required", null)
                                }
                            val file = vmManager.exportContainer(name)
                            if (!isFinishing) runOnUiThread { result.success(file) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_EXPORT_ERROR", e.message, null) }
                        }
                    }

                    "importContainer" -> executor.execute {
                        try {
                            val name = call.argument<String>("name")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_IMPORT_ERROR", "name required", null)
                                }
                            val file = call.argument<String>("file")
                                ?: return@execute runOnUiThread {
                                    result.error("CONTAINER_IMPORT_ERROR", "file required", null)
                                }
                            val output = vmManager.importContainer(name, file)
                            if (!isFinishing) runOnUiThread { result.success(output) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("CONTAINER_IMPORT_ERROR", e.message, null) }
                        }
                    }

                    "saveImage" -> executor.execute {
                        try {
                            val image = call.argument<String>("image")
                                ?: return@execute runOnUiThread {
                                    result.error("IMAGE_SAVE_ERROR", "image required", null)
                                }
                            val file = vmManager.saveImage(image)
                            if (!isFinishing) runOnUiThread { result.success(file) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("IMAGE_SAVE_ERROR", e.message, null) }
                        }
                    }

                    "loadImage" -> executor.execute {
                        try {
                            val file = call.argument<String>("file")
                                ?: return@execute runOnUiThread {
                                    result.error("IMAGE_LOAD_ERROR", "file required", null)
                                }
                            val output = vmManager.loadImage(file)
                            if (!isFinishing) runOnUiThread { result.success(output) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("IMAGE_LOAD_ERROR", e.message, null) }
                        }
                    }

                    "listImages" -> executor.execute {
                        try {
                            val images = vmManager.listImages()
                            if (!isFinishing) runOnUiThread { result.success(images) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("IMAGE_LIST_ERROR", e.message, null) }
                        }
                    }

                    "getPortForwards" -> {
                        result.success(vmManager.getPortForwards())
                    }

                    "addPortForward" -> {
                        val host = call.argument<Int>("host")
                        val guest = call.argument<Int>("guest")
                        val desc = call.argument<String>("desc") ?: ""
                        if (host == null || guest == null || host !in 1..65535 || guest !in 1..65535) {
                            result.error("PORT_ADD_ERROR", "host and guest ports must be 1-65535", null)
                        } else {
                            result.success(vmManager.addPortForward(host, guest, desc))
                        }
                    }

                    "removePortForward" -> {
                        val host = call.argument<Int>("host")
                        if (host == null) {
                            result.error("PORT_REMOVE_ERROR", "host required", null)
                        } else {
                            result.success(vmManager.removePortForward(host))
                        }
                    }

                    "getLanIp" -> {
                        result.success(vmManager.getLanIp())
                    }

                    "hasAllFilesAccess" -> {
                        result.success(vmManager.hasAllFilesAccess())
                    }

                    "getContainerEngine" -> executor.execute {
                        try {
                            val engine = vmManager.getContainerEngine()
                            if (!isFinishing) runOnUiThread { result.success(engine) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("ENGINE_ERROR", e.message, null) }
                        }
                    }

                    "setContainerEngine" -> executor.execute {
                        try {
                            val mode = call.argument<String>("mode") ?: "fasttrack"
                            val engine = vmManager.setContainerEngine(mode)
                            if (!isFinishing) runOnUiThread { result.success(engine) }
                        } catch (e: Exception) {
                            if (!isFinishing) runOnUiThread { result.error("ENGINE_ERROR", e.message, null) }
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

                    "getVmLogs" -> {
                        val logs = vmManager.getVmLogs()
                        result.success(logs)
                    }

                    "clearVmLogs" -> {
                        vmManager.clearVmLogs()
                        result.success(true)
                    }

                    "pickFolder" -> {
                        pendingFolderResult = result
                        try {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                            intent.addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                            startActivityForResult(intent, REQUEST_PICK_FOLDER)
                        } catch (e: Exception) {
                            pendingFolderResult?.error("PICK_FOLDER_ERROR", e.message, null)
                            pendingFolderResult = null
                        }
                    }

                    "requestAllFilesAccess" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            if (!Environment.isExternalStorageManager()) {
                                try {
                                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                                        data = Uri.parse("package:$packageName")
                                    }
                                    startActivity(intent)
                                } catch (e: Exception) {
                                    val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                    startActivity(intent)
                                }
                                result.success(false)
                            } else {
                                result.success(true)
                            }
                        } else {
                            result.success(true)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PICK_FOLDER) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                val path = parseDocumentTreeUri(uri)
                pendingFolderResult?.success(path)
            } else {
                pendingFolderResult?.success(null)
            }
            pendingFolderResult = null
        }
    }

    private fun parseDocumentTreeUri(uri: Uri): String? {
        return try {
            val docId = DocumentsContract.getTreeDocumentId(uri)
            val split = docId.split(":")
            val type = split[0]
            if (type.equals("primary", ignoreCase = true)) {
                if (split.size > 1) {
                    "/storage/emulated/0/" + split[1]
                } else {
                    "/storage/emulated/0"
                }
            } else {
                "/storage/" + type + "/" + (if (split.size > 1) split[1] else "")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing document tree URI: ${e.message}")
            null
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

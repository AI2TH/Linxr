package com.ai2th.linxr

import android.app.ActivityManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.StatFs
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.util.zip.GZIPInputStream

class VmManager(private val context: Context) {
    private val TAG = "VmManager"

    @Volatile private var vmProcess: Process? = null
    @Volatile private var isRunning = false

    private val filesDir: File get() = context.filesDir
    private val vmDir: File get() = File(filesDir, "vm")
    private val bootstrapDir: File get() = File(filesDir, "bootstrap")

    // QEMU binaries installed by Android's PackageManager into nativeLibraryDir
    // as .so files (exec_type SELinux label — safe to execute on Android 10+)
    // libqemu.so     = qemu-system-aarch64
    // libqemu_img.so = qemu-img
    private val nativeLibDir: File
        get() = File(context.applicationInfo.nativeLibraryDir)

    private val flutterPrefs: SharedPreferences
        get() = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    // Bump when base.qcow2.gz changes (forces re-extraction on next launch)
    private val ASSETS_VERSION = "v5"

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    @Synchronized
    fun startVm() {
        Log.d(TAG, "startVm()")
        if (isRunning || vmProcess != null) {
            Log.d(TAG, "Stopping existing VM before restart")
            stopVm()
        }

        val freshExtraction = !assetsReady()
        if (freshExtraction) {
            Log.d(TAG, "Assets not ready, extracting...")
            extractAssets()
        }

        val qemuBin = resolveQemuBinary()
        val vcpu  = getFlutterInt("flutter.vcpu_count", dynamicVcpu())
        val ramMb = getFlutterInt("flutter.ram_mb", dynamicRamMb())

        val baseImage = File(vmDir, "base.qcow2")
        val userImage = File(vmDir, "user.qcow2")

        // Recreate overlay only when base changed or doesn't exist.
        // Persistent overlay preserves installed packages across reboots.
        if (freshExtraction || !userImage.exists()) {
            Log.d(TAG, "Creating fresh user.qcow2 (freshExtraction=$freshExtraction)")
            userImage.delete()
            createUserImage(userImage.absolutePath, baseImage.absolutePath)
        } else {
            Log.d(TAG, "Reusing existing user.qcow2 (state preserved)")
        }

        val cmd = buildQemuCommand(
            qemuBin   = qemuBin.absolutePath,
            baseImage = baseImage.absolutePath,
            userImage = userImage.absolutePath,
            vcpu      = vcpu,
            ramMb     = ramMb
        )
        Log.d(TAG, "QEMU command: ${cmd.joinToString(" ")}")

        vmProcess = ProcessBuilder(cmd).apply {
            environment()["LD_LIBRARY_PATH"] = nativeLibDir.absolutePath
            redirectErrorStream(true)
        }.start()

        isRunning = true

        // Drain QEMU stdout/stderr on a daemon thread to prevent pipe buffer deadlock
        Thread {
            try {
                vmProcess?.inputStream?.bufferedReader()?.forEachLine { line ->
                    Log.d("QEMU", line)
                }
            } catch (e: Exception) {
                Log.w(TAG, "QEMU output reader closed: ${e.message}")
            }
        }.apply { isDaemon = true; start() }

        Log.d(TAG, "VM process launched")
    }

    @Synchronized
    fun stopVm() {
        Log.d(TAG, "stopVm()")
        vmProcess?.let { proc ->
            proc.destroy()  // SIGTERM first
            if (!proc.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)) {
                Log.w(TAG, "QEMU did not exit in 5s, force-killing")
                proc.destroyForcibly()
                proc.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)
            }
        }
        vmProcess = null
        isRunning = false
        Log.d(TAG, "VM stopped")
    }

    fun getStatus(): String {
        vmProcess?.let {
            return try {
                it.exitValue()
                isRunning = false
                vmProcess = null
                "stopped"
            } catch (_: IllegalThreadStateException) {
                "running"
            }
        }
        return "stopped"
    }

    // -------------------------------------------------------------------------
    // QEMU command builder
    // -------------------------------------------------------------------------

    private fun buildQemuCommand(
        qemuBin: String, baseImage: String, userImage: String,
        vcpu: Int, ramMb: Int
    ): List<String> {
        val cmd = mutableListOf<String>()
        cmd += qemuBin

        if (isArm64()) {
            cmd += listOf("-machine", "virt")
            cmd += listOf("-cpu", "cortex-a53")
        } else {
            cmd += listOf("-machine", "q35")
            cmd += listOf("-cpu", "qemu64")
        }

        cmd += listOf("-smp", vcpu.toString())
        cmd += listOf("-m", ramMb.toString())
        cmd += listOf("-drive", "if=none,file=$baseImage,id=base,format=qcow2,readonly=on")
        cmd += listOf("-drive", "if=none,file=$userImage,id=user,format=qcow2")
        cmd += listOf("-device", "virtio-blk-pci,drive=user")
        // SSH forward only: host 2222 → guest 22
        cmd += listOf("-netdev", "user,id=net0,hostfwd=tcp::2222-:22")
        cmd += listOf("-device", "virtio-net-pci,netdev=net0,romfile=")
        cmd += listOf("-display", "none")
        cmd += listOf("-serial", "stdio")

        val kernel = File(vmDir, "vmlinuz-virt")
        val initrd  = File(vmDir, "initramfs-virt")
        if (kernel.exists() && initrd.exists()) {
            cmd += listOf("-kernel", kernel.absolutePath)
            cmd += listOf("-initrd", initrd.absolutePath)
            cmd += listOf("-append",
                "console=ttyAMA0 root=/dev/vda rootfstype=ext4 rootflags=rw " +
                "modules=virtio_blk,ext4 quiet")
        }
        return cmd
    }

    // -------------------------------------------------------------------------
    // Asset extraction
    // -------------------------------------------------------------------------

    private fun assetsReady(): Boolean {
        val marker = File(filesDir, "assets_extracted.$ASSETS_VERSION")
        return marker.exists()
            && resolveQemuBinary().exists()
            && File(vmDir, "base.qcow2").exists()
            && File(vmDir, "vmlinuz-virt").exists()
            && File(vmDir, "initramfs-virt").exists()
    }

    private fun extractAssets() {
        // Remove old version markers
        filesDir.listFiles()?.filter { it.name.startsWith("assets_extracted.") }
            ?.forEach { it.delete() }

        vmDir.mkdirs()
        bootstrapDir.mkdirs()

        // base.qcow2.gz — aapt2 may pre-decompress .gz and drop the extension
        val baseQcow2 = File(vmDir, "base.qcow2")
        if (!baseQcow2.exists()) {
            try {
                extractAsset("vm/base.qcow2", baseQcow2)
                Log.d(TAG, "Extracted base.qcow2 (aapt2 pre-decompressed)")
            } catch (_: Exception) {
                extractAndDecompress("vm/base.qcow2.gz", baseQcow2)
                Log.d(TAG, "Extracted + decompressed base.qcow2.gz")
            }
        }

        listOf("vmlinuz-virt", "initramfs-virt").forEach { name ->
            val dest = File(vmDir, name)
            if (!dest.exists()) extractAsset("vm/$name", dest)
        }

        // Bootstrap script
        runCatching { extractAsset("bootstrap/init_bootstrap.sh", File(bootstrapDir, "init_bootstrap.sh")) }
            .onFailure { Log.w(TAG, "Bootstrap asset not found: ${it.message}") }

        File(filesDir, "assets_extracted.$ASSETS_VERSION").createNewFile()
        Log.d(TAG, "Assets extracted ($ASSETS_VERSION)")
    }

    private fun extractAsset(assetPath: String, dest: File) {
        context.assets.open(assetPath).use { input ->
            FileOutputStream(dest).use { input.copyTo(it) }
        }
    }

    private fun extractAndDecompress(assetPath: String, dest: File) {
        context.assets.open(assetPath).use { raw ->
            GZIPInputStream(raw).use { gz ->
                FileOutputStream(dest).use { gz.copyTo(it) }
            }
        }
    }

    // -------------------------------------------------------------------------
    // qemu-img: create QCOW2 overlay
    // -------------------------------------------------------------------------

    private fun createUserImage(userImagePath: String, baseImagePath: String) {
        val qemuImg = File(nativeLibDir, "libqemu_img.so")
        if (!qemuImg.exists()) throw IllegalStateException(
            "libqemu_img.so not found in $nativeLibDir"
        )
        val prefDiskGb = getFlutterInt("flutter.disk_gb", 0).toLong()
        val sizeGb = if (prefDiskGb > 0) prefDiskGb else availableOverlaySizeGb()
        Log.d(TAG, "Creating user.qcow2 with ${sizeGb}G virtual size (pref=${prefDiskGb}G)")
        val proc = ProcessBuilder(
            qemuImg.absolutePath, "create",
            "-f", "qcow2", "-b", baseImagePath, "-F", "qcow2",
            userImagePath, "${sizeGb}G"
        ).apply {
            environment()["LD_LIBRARY_PATH"] = nativeLibDir.absolutePath
        }.start()
        val exitCode = proc.waitFor()
        if (exitCode != 0) {
            val err = proc.errorStream.bufferedReader().readText()
            throw RuntimeException("qemu-img create failed (exit $exitCode): $err")
        }
        Log.d(TAG, "Created user.qcow2 at $userImagePath")
    }

    // Returns a virtual disk size (GB) sized to the phone's available storage,
    // minus 2 GB headroom. QCOW2 is sparse so this costs nothing until written.
    private fun availableOverlaySizeGb(): Long {
        return try {
            val stat = StatFs(filesDir.absolutePath)
            val availableGb = (stat.availableBlocksLong * stat.blockSizeLong) / (1024L * 1024 * 1024)
            (availableGb - 2L).coerceAtLeast(8L)
        } catch (_: Exception) {
            8L
        }
    }

    // Half the device's CPU cores, clamped to [1, cores].
    private fun dynamicVcpu(): Int =
        (Runtime.getRuntime().availableProcessors() / 2).coerceAtLeast(1)

    // 25% of device total RAM in MB, clamped to [512, totalRam].
    private fun dynamicRamMb(): Int {
        return try {
            val info = ActivityManager.MemoryInfo()
            (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
                .getMemoryInfo(info)
            val totalMb = (info.totalMem / (1024L * 1024)).toInt()
            (totalMb / 4).coerceAtLeast(512)
        } catch (_: Exception) {
            1024
        }
    }

    fun getDeviceInfo(): Map<String, Any> {
        val cores = Runtime.getRuntime().availableProcessors()
        val ramInfo = ActivityManager.MemoryInfo()
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
            .getMemoryInfo(ramInfo)
        val totalRamMb = (ramInfo.totalMem / (1024L * 1024)).toInt()
        val stat = StatFs(filesDir.absolutePath)
        val freeStorageGb = ((stat.availableBlocksLong * stat.blockSizeLong) / (1024L * 1024 * 1024)).toInt()
        return mapOf(
            "cores"        to cores,
            "totalRamMb"   to totalRamMb,
            "freeStorageGb" to freeStorageGb
        )
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private fun resolveQemuBinary(): File {
        val bin = File(nativeLibDir, "libqemu.so")
        if (!bin.exists()) throw IllegalStateException(
            "libqemu.so not found in $nativeLibDir"
        )
        return bin
    }

    private fun isArm64(): Boolean =
        Build.SUPPORTED_ABIS.any { it.startsWith("arm64") }

    private fun getFlutterInt(key: String, default: Int): Int {
        return try {
            flutterPrefs.getInt(key, default)
        } catch (_: ClassCastException) {
            flutterPrefs.getLong(key, default.toLong()).toInt()
        }
    }
}

package com.ai2th.linxr

import android.content.Context
import android.os.StatFs
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.JSch
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetSocketAddress
import java.net.Socket

/**
 * End-to-end check for disk resize (#27, #34): with a 16 GB disk set in
 * Settings, a fresh user.qcow2 is created at 16 GB and init_bootstrap.sh grows
 * the root filesystem online, so `df /` inside the VM reports more than 15 GB.
 *
 * Needs a device with the VM assets in the APK and at least 18 GB free
 * (VmManager caps the disk to free storage minus 2 GB); skipped otherwise.
 * Run: ./gradlew connectedDebugAndroidTest
 *   -Pandroid.testInstrumentationRunnerArguments.class=com.ai2th.linxr.VmDiskResizeTest
 */
@RunWith(AndroidJUnit4::class)
class VmDiskResizeTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val vmManager get() = (context.applicationContext as AlpineApp).vmManager
    private var session: Session? = null

    @Before
    fun setUp() {
        val stat = StatFs(context.filesDir.absolutePath)
        val freeGb = stat.availableBlocksLong * stat.blockSizeLong / (1024L * 1024 * 1024)
        assumeTrue("Needs at least ${REQUIRED_FREE_GB} GB free (has $freeGb GB)", freeGb >= REQUIRED_FREE_GB)

        try { vmManager.stopVm() } catch (_: Exception) {}
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit().putLong("flutter.disk_gb", DISK_GB).commit()
        // A new overlay is created at the configured size on the next start.
        vmManager.resetStorage()
    }

    @After
    fun tearDown() {
        session?.disconnect()
        session = null
        try { vmManager.stopVm() } catch (_: Exception) {}
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit().remove("flutter.disk_gb").commit()
        vmManager.resetStorage()
    }

    @Test(timeout = 20 * 60_000L)
    fun rootFilesystemGrowsToConfiguredDiskSize() {
        vmManager.startVm()
        waitForSshPort()
        val s = openSession()
        session = s

        val blockBytes = exec(s, "cat /sys/block/vda/size").trim().toLong() * 512
        Log.i(TAG, "vda size: ${blockBytes / MIB} MiB")
        assertTrue("user.qcow2 was not created at ${DISK_GB} GB (vda is ${blockBytes / MIB} MiB)",
            blockBytes > MIN_ROOT_BYTES)

        // resize2fs runs in the background during boot; poll until it is done.
        val deadline = System.currentTimeMillis() + 10 * 60_000L
        var rootBytes = 0L
        while (System.currentTimeMillis() < deadline) {
            // df -k: 1K-blocks of the root filesystem.
            val kb = exec(s, "df -k / | awk 'NR==2 {print \$2}'").trim().toLongOrNull() ?: 0L
            rootBytes = kb * 1024
            Log.i(TAG, "df / size: ${rootBytes / MIB} MiB")
            if (rootBytes > MIN_ROOT_BYTES) break
            Thread.sleep(10_000)
        }
        Log.i(TAG, "resize log:\n" + exec(s, "cat /var/log/resize.log 2>/dev/null"))
        assertTrue("Root filesystem is ${rootBytes / MIB} MiB, expected more than 15 GB",
            rootBytes > MIN_ROOT_BYTES)
    }

    private fun waitForSshPort() {
        val deadline = System.currentTimeMillis() + 5 * 60_000L
        while (System.currentTimeMillis() < deadline) {
            try {
                Socket().use { it.connect(InetSocketAddress("127.0.0.1", 2222), 5_000) }
                return
            } catch (_: Exception) {
                Thread.sleep(3_000)
            }
        }
        throw AssertionError("VM SSH port not open within 5 minutes")
    }

    private fun openSession(): Session {
        val deadline = System.currentTimeMillis() + 5 * 60_000L
        val jsch = JSch()
        while (System.currentTimeMillis() < deadline) {
            // Per-install password; the image's legacy password only works
            // until the guest has applied it.
            for (password in listOf(vmManager.rootPassword, "alpine")) {
                val session = jsch.getSession("root", "127.0.0.1", 2222)
                session.setPassword(password)
                session.setConfig("StrictHostKeyChecking", "no")
                session.setConfig("PreferredAuthentications", "password")
                try {
                    session.connect(30_000)
                    return session
                } catch (e: JSchException) {
                    Log.w(TAG, "SSH login failed: ${e.message}")
                }
            }
            Thread.sleep(5_000)
        }
        throw AssertionError("Could not log in over SSH within 5 minutes")
    }

    private fun exec(session: Session, cmd: String): String {
        val channel = session.openChannel("exec") as ChannelExec
        channel.setCommand(cmd)
        val input = channel.inputStream
        channel.connect(10_000)
        val output = input.bufferedReader().readText()
        channel.disconnect()
        return output
    }

    companion object {
        private const val TAG = "VmDiskResizeTest"
        private const val DISK_GB = 16L
        private const val REQUIRED_FREE_GB = DISK_GB + 2
        private const val MIB = 1024L * 1024
        private const val MIN_ROOT_BYTES = 15L * 1024 * 1024 * 1024
    }
}

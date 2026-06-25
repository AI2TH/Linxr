package com.ai2th.linxr

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetSocketAddress
import java.net.Socket

@RunWith(AndroidJUnit4::class)
class VmResourceTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val vmManager get() = (context.applicationContext as AlpineApp).vmManager

    @Before
    fun startVm() {
        Log.i(TAG, ">>> startVm")
        vmManager.startVm()
    }

    @After
    fun stopVm() {
        try { vmManager.stopVm() } catch (_: Exception) {}
    }

    @Test(timeout = 6_000_000) // 100 min
    fun checkVmResources() {
        waitForSsh()

        Thread.sleep(2_000) // let sshd finish initialising

        val session = openSession()
        try {
            // ── Diagnostics: device vs filesystem size ──────────────────────
            val devSizeBytes = exec(session, "blockdev --getsize64 /dev/vda 2>&1")
            val resizeLog    = exec(session, "cat /tmp/resize.log 2>/dev/null || echo 'no resize log'")
            val nproc        = exec(session, "nproc")
            val free         = exec(session, "free -h")
            val kernel       = exec(session, "uname -r")
            val alpine       = exec(session, "cat /etc/alpine-release 2>/dev/null || echo n/a")
            var df           = exec(session, "df -h /")

            Log.i(TAG, "══════════════════════════════════════════")
            Log.i(TAG, "  LINXR VM RESOURCE CHECK")
            Log.i(TAG, "══════════════════════════════════════════")
            Log.i(TAG, "Kernel  : ${kernel.trim()}")
            Log.i(TAG, "Alpine  : ${alpine.trim()}")
            Log.i(TAG, "CPU     : $nproc vCPU(s)")
            Log.i(TAG, "")
            Log.i(TAG, "RAM (free -h):")
            free.lines().forEach { Log.i(TAG, "  $it") }
            Log.i(TAG, "")
            Log.i(TAG, "/dev/vda size (bytes): ${devSizeBytes.trim()}")
            Log.i(TAG, "")
            Log.i(TAG, "first-boot-resize log:")
            resizeLog.lines().forEach { Log.i(TAG, "  $it") }
            Log.i(TAG, "")
            Log.i(TAG, "DISK before manual resize (df -h /):")
            df.lines().forEach { Log.i(TAG, "  $it") }
            Log.i(TAG, "")

            // ── If disk still small, try resize2fs manually via SSH ─────────
            val sizeFieldBefore = df.lines().drop(1).firstOrNull()
                ?.trim()?.split("\\s+".toRegex())?.getOrNull(1) ?: "0G"
            val sizeNumBefore = sizeFieldBefore.trimEnd('G', 'T', 'M').toDoubleOrNull() ?: 0.0
            val isSmall = !sizeFieldBefore.endsWith("G") || sizeNumBefore <= 5.0

            if (isSmall) {
                Log.i(TAG, "Disk small — attempting manual resize2fs via SSH...")
                val resizeOut = exec(session, "resize2fs /dev/vda 2>&1; echo \"exit=\$?\"")
                Log.i(TAG, "resize2fs output: $resizeOut")
                Thread.sleep(1000)
                df = exec(session, "df -h /")
                Log.i(TAG, "DISK after manual resize (df -h /):")
                df.lines().forEach { Log.i(TAG, "  $it") }
            }

            Log.i(TAG, "══════════════════════════════════════════")

            // ── Assertions ──────────────────────────────────────────────────
            val sizeField = df.lines().drop(1).firstOrNull()
                ?.trim()?.split("\\s+".toRegex())?.getOrNull(1) ?: "0G"
            val sizeNum = sizeField.trimEnd('G', 'T', 'M').toDoubleOrNull() ?: 0.0
            val isGb = sizeField.endsWith("G") || sizeField.endsWith("T")
            assertTrue("Disk too small: $sizeField — expected >5G (manual resize also failed)", isGb && sizeNum > 5.0)

            Log.i(TAG, "✓ All checks passed")
        } finally {
            session.disconnect()
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private fun waitForSsh() {
        val deadline = System.currentTimeMillis() + 90 * 60_000L
        Log.i(TAG, "Waiting for SSH on 127.0.0.1:2222 (up to 90 min)...")
        while (System.currentTimeMillis() < deadline) {
            try {
                Socket().use { it.connect(InetSocketAddress("127.0.0.1", 2222), 3_000) }
                Log.i(TAG, "SSH port open")
                return
            } catch (_: Exception) {
                Thread.sleep(5_000)
            }
        }
        throw AssertionError("VM SSH not ready within 90 minutes")
    }

    private fun openSession(): Session {
        val deadline = System.currentTimeMillis() + 90 * 60_000L
        val jsch = JSch()
        while (System.currentTimeMillis() < deadline) {
            try {
                val session = jsch.getSession("root", "127.0.0.1", 2222)
                session.setPassword("alpine")
                session.setConfig("StrictHostKeyChecking", "no")
                session.setConfig("PreferredAuthentications", "password")
                session.connect(15_000)
                return session
            } catch (e: Exception) {
                Log.w(TAG, "SSH connection attempt failed: ${e.message}, retrying in 5s...")
                try { Thread.sleep(5_000) } catch (_: InterruptedException) {}
            }
        }
        throw AssertionError("Failed to connect SSH session within 90 minutes")
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
        private const val TAG = "VM_CHECK"
    }
}

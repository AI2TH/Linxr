package com.ai2th.linxr

import android.content.Context
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class VmE2ETest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val vmManager get() = (context.applicationContext as AlpineApp).vmManager
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    private val defaultSdcardPath = "/storage/emulated/0/LinxrShare"
    private var currentSession: Session? = null

    @Before
    fun setUp() {
        Log.i(TAG, ">>> setUp: cleaning VM state")
        try { vmManager.stopVm() } catch (_: Exception) {}

        // Configure disk limit to 8GB
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        prefs.edit().putLong("flutter.disk_gb", 8L).commit()

        val baseImage = File(context.filesDir, "vm/base.qcow2")
        baseImage.delete() // Force clean extraction of the new base.qcow2.gz

        val userImage = File(context.filesDir, "vm/user.qcow2")
        userImage.delete() // Force clean recreation at 8GB
        vmManager.resetStorage()
    }

    @After
    fun tearDown() {
        Log.i(TAG, ">>> tearDown: stopping VM")
        currentSession?.let { session ->
            if (session.isConnected) {
                printGuestDiagnostics(session)
            }
        }
        try { vmManager.stopVm() } catch (_: Exception) {}
        currentSession = null
    }

    @Test(timeout = 720000) // 12 minutes
    fun testVmEndToEndAndDocker() {
        // ─────────────────────────────────────────────────────────────────────
        // 1. Configure CPU/Memory resources (vCPU = 2, RAM = 1024)
        // ─────────────────────────────────────────────────────────────────────
        Log.i(TAG, "Configuring VM resources: 2 vCPU, 1024MB RAM")
        vmManager.overrideVcpu = 2
        vmManager.overrideRamMb = 1024

        // ─────────────────────────────────────────────────────────────────────
        // 2. Setup shared folder and write a test file
        // ─────────────────────────────────────────────────────────────────────
        val sharedDir = File(context.filesDir, "LinxrShare")
        if (!sharedDir.exists()) {
            sharedDir.mkdirs()
        }
        
        // Point the VM shared folder path to our private directory
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        prefs.edit().putString("flutter.sdcard_path", sharedDir.absolutePath).commit()

        val testFile = File(sharedDir, "linxr_e2e_test.txt")
        val expectedContent = "Linxr E2E Test Content - Timestamp ${System.currentTimeMillis()}"
        testFile.writeText(expectedContent)
        Log.i(TAG, "Wrote test file to shared host folder: ${testFile.absolutePath}")

        // ─────────────────────────────────────────────────────────────────────
        // 3. Start the VM
        // ─────────────────────────────────────────────────────────────────────
        Log.i(TAG, "Starting VM...")
        vmManager.startVm()

        // Wait for SSH port to open
        waitForSsh()
        Thread.sleep(3000) // Allow boot scripts to settle

        val session = openSession()
        currentSession = session
        try {
            // ─────────────────────────────────────────────────────────────────────
            // 4. Verify VM showing exact value of memory and CPU settings
            // ─────────────────────────────────────────────────────────────────────
            val nproc = exec(session, "nproc").trim()
            Log.i(TAG, "VM CPU count reported: $nproc")
            assertEquals("VM did not reflect CPU configuration", "2", nproc)

            val freeMem = exec(session, "free -m")
            Log.i(TAG, "VM memory info:\n$freeMem")
            // Parse total RAM in MB (second line, second field)
            val lines = freeMem.lines().map { it.trim() }
            val memLine = lines.firstOrNull { it.startsWith("Mem:") } ?: ""
            val totalRam = memLine.split("\\s+".toRegex()).getOrNull(1)?.toIntOrNull() ?: 0
            Log.i(TAG, "VM total memory reported: $totalRam MB")
            // Allow some offset for kernel allocation
            assertTrue("VM did not reflect RAM configuration (reported $totalRam MB)", totalRam in 800..1050)

            // ─────────────────────────────────────────────────────────────────────
            // 5. Verify shared folder 9p mount and visibility of the test file
            // ─────────────────────────────────────────────────────────────────────
            Log.i(TAG, "Checking shared folder file visibility inside VM...")
            val mountCheck = exec(session, "mount | grep sdcard").trim()
            Log.i(TAG, "Mount check output: $mountCheck")
            
            val catOutput = exec(session, "cat /mnt/sdcard/linxr_e2e_test.txt 2>/dev/null").trim()
            Log.i(TAG, "Cat output from VM shared folder: $catOutput")
            assertEquals("Shared file contents did not match", expectedContent, catOutput)

            // ─────────────────────────────────────────────────────────────────────
            // 6. Verify dockerd and api_server.py are running automatically on start
            // ─────────────────────────────────────────────────────────────────────
            Log.i(TAG, "Checking if dockerd and api_server are running...")
            val mountLog = exec(session, "cat /tmp/sdcard_mount.log 2>/dev/null").trim()
            Log.i(TAG, "/tmp/sdcard_mount.log contents:\n$mountLog")
            val lsBootstrap = exec(session, "ls -la /bootstrap 2>/dev/null").trim()
            Log.i(TAG, "ls -la /bootstrap contents:\n$lsBootstrap")
            val lsSdcard = exec(session, "ls -la /mnt/sdcard 2>/dev/null").trim()
            Log.i(TAG, "ls -la /mnt/sdcard contents:\n$lsSdcard")
            val dockerdCheck = exec(session, "pgrep dockerd").trim()
            Log.i(TAG, "dockerd pgrep PID: $dockerdCheck")
            if (dockerdCheck.isEmpty()) {
                val dockerdLog = exec(session, "cat /tmp/dockerd.log 2>/dev/null").trim()
                Log.e(TAG, "GUEST /tmp/dockerd.log contents:\n$dockerdLog")
                val dockerdLog2 = exec(session, "cat /var/log/dockerd.log 2>/dev/null").trim()
                Log.e(TAG, "GUEST /var/log/dockerd.log contents:\n$dockerdLog2")
                val dmesg = exec(session, "dmesg | tail -n 50").trim()
                Log.e(TAG, "GUEST dmesg tail:\n$dmesg")
            }
            assertTrue("dockerd is not running", dockerdCheck.isNotEmpty())

            val apiServerCheck = exec(session, "pgrep -f api_server.py").trim()
            Log.i(TAG, "api_server pgrep PID: $apiServerCheck")
            assertTrue("api_server.py is not running", apiServerCheck.isNotEmpty())

            // Test REST API health check endpoint from host using token
            val appPrefs = context.getSharedPreferences("vm_app_prefs", Context.MODE_PRIVATE)
            val token = appPrefs.getString("api_token", "") ?: ""
            Log.i(TAG, "Querying guest FastAPI health check from host...")
            
            val request = Request.Builder()
                .url("http://127.0.0.1:7081/health")
                .header("Authorization", "Bearer $token")
                .build()

            var lastException: Exception? = null
            var healthSuccess = false
            val apiHealthDeadline = System.currentTimeMillis() + 240_000L
            while (System.currentTimeMillis() < apiHealthDeadline) {
                var response: okhttp3.Response? = null
                try {
                    response = httpClient.newCall(request).execute()
                    Log.i(TAG, "FastAPI /health response code: ${response.code}")
                    if (response.isSuccessful) {
                        healthSuccess = true
                    }
                } catch (e: Exception) {
                    lastException = e
                    Log.d(TAG, "FastAPI health check failed: ${e.message}, retrying in 2s...")
                } finally {
                    response?.close()
                }
                
                if (healthSuccess) {
                    break
                }
                try { Thread.sleep(2000) } catch (_: InterruptedException) {}
            }
            
            if (!healthSuccess) {
                Log.e(TAG, "REST API call failed: ${lastException?.message}")
                printGuestDiagnostics(session)
                throw lastException ?: AssertionError("FastAPI server health check failed")
            }

            Log.i(TAG, "Waiting for Docker daemon to be fully ready...")
            var dockerReady = false
            for (i in 1..45) {
                val infoResult = exec(session, "timeout 5 docker info >/dev/null 2>&1; echo $?").trim()
                if (infoResult == "0") {
                    dockerReady = true
                    Log.i(TAG, "Docker daemon is ready after ${i * 2}s")
                    break
                }
                try { Thread.sleep(2000) } catch (_: InterruptedException) {}
            }
            if (!dockerReady) {
                printGuestDiagnostics(session)
                assertTrue("Docker daemon failed to become ready", dockerReady)
            }

            // ─────────────────────────────────────────────────────────────────────
            // 7. Verify docker build inside the VM
            // ─────────────────────────────────────────────────────────────────────
            Log.i(TAG, "Running docker build test inside VM...")
            exec(session, "mkdir -p /tmp/docker-build-test")
            exec(session, "echo -e 'FROM alpine\\nRUN echo \"Linxr E2E Build success\"' > /tmp/docker-build-test/Dockerfile")
            val dockerBuildOutput = exec(session, "docker build -t linxr-e2e-image /tmp/docker-build-test 2>&1")
            Log.i(TAG, "Docker build output:\n$dockerBuildOutput")
            assertTrue("Docker build did not succeed", dockerBuildOutput.contains("Successfully tagged linxr-e2e-image:latest"))

            // ─────────────────────────────────────────────────────────────────────
            // 8. Verify network reachability and domain lookup
            // ─────────────────────────────────────────────────────────────────────
            Log.i(TAG, "Testing internet reachability...")
            val pingOutput = exec(session, "ping -c 3 -W 5 8.8.8.8 2>&1")
            Log.i(TAG, "Ping 8.8.8.8 output:\n$pingOutput")
            assertTrue("Internet is not reachable (ping failed)", pingOutput.contains("3 packets transmitted, 3 packets received"))

            val nslookupOutput = exec(session, "nslookup google.com 2>&1")
            Log.i(TAG, "nslookup google.com output:\n$nslookupOutput")
            assertTrue("DNS resolution failed", nslookupOutput.contains("Address:"))

        } catch (e: Throwable) {
            val wasInterrupted = Thread.interrupted()
            Log.e(TAG, "Test failed with exception: ${e.message} (wasInterrupted=$wasInterrupted)", e)
            try {
                printGuestDiagnostics(session)
            } catch (diagEx: Exception) {
                Log.e(TAG, "Diagnostics collection failed", diagEx)
            }
            if (wasInterrupted) {
                Thread.currentThread().interrupt() // Restore interrupt status
            }
            throw e
        } finally {
            session.disconnect()
            // Clean up host test file
            testFile.delete()
        }
    }

    private fun waitForSsh() {
        val deadline = System.currentTimeMillis() + 180 * 1000L
        Log.i(TAG, "Waiting for SSH on 127.0.0.1:2222 (up to 180 seconds)...")
        while (System.currentTimeMillis() < deadline) {
            try {
                Socket().use { it.connect(InetSocketAddress("127.0.0.1", 2222), 5000) }
                Log.i(TAG, "SSH port is open")
                return
            } catch (_: Exception) {
                Thread.sleep(3000)
            }
        }
        throw AssertionError("VM SSH not ready within timeout")
    }

    private fun openSession(): Session {
        val deadline = System.currentTimeMillis() + 300_000L
        val jsch = JSch()
        while (System.currentTimeMillis() < deadline) {
            try {
                val session = jsch.getSession("root", "127.0.0.1", 2222)
                session.setPassword("alpine")
                session.setConfig("StrictHostKeyChecking", "no")
                session.setConfig("PreferredAuthentications", "password")
                session.connect(30000)
                return session
            } catch (e: Exception) {
                Log.w(TAG, "SSH connection attempt failed: ${e.message}, retrying in 5s...")
                try { Thread.sleep(5000) } catch (_: InterruptedException) {}
            }
        }
        throw AssertionError("Failed to establish SSH session within 3 minutes")
    }

    private fun exec(session: Session, cmd: String): String {
        val channel = session.openChannel("exec") as ChannelExec
        channel.setCommand(cmd)
        val input = channel.inputStream
        channel.connect(10000)
        val output = input.bufferedReader().readText()
        channel.disconnect()
        return output
    }

    private fun printGuestDiagnostics(session: Session) {
        try {
            val psOutput = exec(session, "ps w").trim()
            Log.e(TAG, "GUEST ps w output:\n$psOutput")
            val netstatOutput = exec(session, "netstat -an").trim()
            Log.e(TAG, "GUEST netstat -an output:\n$netstatOutput")
            val logDirListing = exec(session, "ls -la /var/log").trim()
            Log.e(TAG, "GUEST /var/log listing:\n$logDirListing")
            val apiLog = exec(session, "cat /var/log/api_server.log 2>/dev/null").trim()
            Log.e(TAG, "GUEST /var/log/api_server.log contents:\n$apiLog")
            val bootstrapLog = exec(session, "cat /var/log/bootstrap.log 2>/dev/null").trim()
            Log.e(TAG, "GUEST /var/log/bootstrap.log contents:\n$bootstrapLog")
            val dockerdLog = exec(session, "cat /var/log/dockerd.log 2>/dev/null").trim()
            Log.e(TAG, "GUEST /var/log/dockerd.log contents:\n$dockerdLog")
            val tmpDockerdLog = exec(session, "cat /tmp/dockerd.log 2>/dev/null").trim()
            Log.e(TAG, "GUEST /tmp/dockerd.log contents:\n$tmpDockerdLog")
            val containerdLog = exec(session, "cat /var/log/containerd.log 2>/dev/null").trim()
            Log.e(TAG, "GUEST /var/log/containerd.log contents:\n$containerdLog")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to collect guest diagnostics: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "VmE2ETest"
    }
}

package com.ai2th.linxr

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps the app process (and the QEMU child process)
 * alive while the VM runs.
 *
 * Type: dataSync (see the comment in AndroidManifest.xml for why not
 * specialUse). On Android 15+ a dataSync service may run 6 hours in 24 while
 * the app is in the background; [onTimeout] stops it cleanly and tells the
 * user, and MainActivity starts it again when the app returns to the
 * foreground (which resets the limit).
 */
class VmService : Service() {
    companion object {
        private const val TAG = "VmService"

        /** Whether the service is currently in the started state. */
        @Volatile
        var isActive = false
            private set
    }
    private val CHANNEL_ID = "linxr_channel"
    private val NOTIFICATION_ID = 1
    private val TIMEOUT_NOTIFICATION_ID = 2

    private val vmManager: VmManager get() = (application as AlpineApp).vmManager

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "VmService created")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Call startForeground first in every case: a start through
        // startForegroundService() must reach it in time, even when the
        // service is about to stop again.
        try {
            startForeground(NOTIFICATION_ID, createNotification())
        } catch (e: Exception) {
            // Android 12+ refuses a foreground start from the background
            // (e.g. a sticky restart). Without it there is nothing to keep.
            Log.w(TAG, "startForeground refused: ${e.javaClass.simpleName}: ${e.message}")
            isActive = false
            stopSelf(startId)
            return START_NOT_STICKY
        }

        // A null intent is a START_STICKY restart after Android killed the
        // app process. QEMU was a child of that process, so this VmManager
        // has no VM: do not show "VM is running" for a VM that is gone.
        if (intent == null && runCatching { vmManager.getStatus() }.getOrNull() != "running") {
            Log.w(TAG, "Sticky restart without a running VM; stopping the service")
            isActive = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }

        Log.d(TAG, "VmService started (restart=${intent == null})")
        isActive = true
        getSystemService(NotificationManager::class.java)?.cancel(TIMEOUT_NOTIFICATION_ID)
        return START_STICKY
    }

    override fun onDestroy() {
        // Do NOT stop the VM here. If the user swipes the app away, Android
        // destroys the service; we want the QEMU process (and any daemons
        // inside the VM, e.g. dockerd) to keep running. The VM is stopped only
        // when the user explicitly taps Stop VM, which calls vmManager.stopVm()
        // and stopVmService() from MainActivity.
        isActive = false
        super.onDestroy()
        Log.d(TAG, "VmService destroyed — VM left running")
    }

    // Android 15+ (targetSdk 35+) limits dataSync foreground services to 6 hours
    // in 24 and then calls onTimeout(). If the service does not stop within a
    // few seconds the system crashes the app
    // (ForegroundServiceDidNotStopInTimeException). Stop cleanly instead and
    // tell the user: QEMU keeps running, but without the foreground service
    // Android may kill the app (and the VM) under memory pressure. Opening the
    // app resets the limit and MainActivity.onResume starts the service again.
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "Foreground service time limit reached (type=$fgsType), stopping service")
        isActive = false
        postTimeoutNotification()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Linxr",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Alpine Linux VM background service" }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun contentIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_IMMUTABLE
    )

    private fun createNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Linxr")
            .setContentText("VM is running — SSH on port 2222")
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setContentIntent(contentIntent())
            .setOngoing(true)
            .build()
    }

    private fun postTimeoutNotification() {
        val n = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Linxr: VM may be stopped by Android")
            .setContentText("Android's 6-hour background limit was reached. Open Linxr to keep the VM running.")
            .setStyle(NotificationCompat.BigTextStyle().bigText(
                "Android's 6-hour limit for background services was reached. The VM is " +
                "still running, but Android may now stop it to free memory. Open Linxr " +
                "to keep it running."
            ))
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentIntent(contentIntent())
            .setAutoCancel(true)
            .build()
        runCatching {
            getSystemService(NotificationManager::class.java)?.notify(TIMEOUT_NOTIFICATION_ID, n)
        }.onFailure { Log.w(TAG, "Could not post the timeout notification: ${it.message}") }
    }
}

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

class VmService : Service() {
    companion object {
        private const val TAG = "VmService"
    }
    private val CHANNEL_ID = "linxr_channel"
    private val NOTIFICATION_ID = 1

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "VmService created")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "VmService started")
        startForeground(NOTIFICATION_ID, createNotification())
        return START_STICKY
    }

    override fun onDestroy() {
        // Do NOT stop the VM here. If the user swipes the app away, Android
        // destroys the service; we want the QEMU process (and any daemons
        // inside the VM, e.g. dockerd) to keep running. The VM is stopped only
        // when the user explicitly taps Stop VM, which calls vmManager.stopVm()
        // and stopVmService() from MainActivity.
        super.onDestroy()
        Log.d(TAG, "VmService destroyed — VM left running")
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

    private fun createNotification(): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Linxr")
            .setContentText("VM is running — SSH on port 2222")
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }
}

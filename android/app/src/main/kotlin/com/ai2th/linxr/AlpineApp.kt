package com.ai2th.linxr

import android.app.Application

/**
 * Application singleton that holds VmManager so it survives Activity recreations.
 */
class AlpineApp : Application() {
    lateinit var vmManager: VmManager
        private set

    override fun onCreate() {
        super.onCreate()
        vmManager = VmManager(this)
    }
}

package com.ai2th.linxr

import android.util.Log
import com.google.gson.Gson
import com.google.gson.JsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

class VmApiClient(private val token: String) {
    private val TAG = "VmApiClient"
    private val baseUrl = "http://127.0.0.1:7081"
    private val gson = Gson()

    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    // docker pull (300s) + docker run (30s) + buffer = 360s
    private val containerClient = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(360, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private fun Request.Builder.withAuth(): Request.Builder =
        header("Authorization", "Bearer $token")

    fun checkHealth(): Boolean {
        return try {
            val request = Request.Builder()
                .url("$baseUrl/health")
                .withAuth()
                .get()
                .build()

            val response = client.newCall(request).execute()
            val success = response.isSuccessful
            response.close()
            success
        } catch (e: Exception) {
            Log.e(TAG, "Health check failed: ${e.message}")
            false
        }
    }

    fun startContainer(image: String, name: String, cmd: List<String>) {
        val json = JsonObject().apply {
            addProperty("image", image)
            addProperty("name", name)
            add("cmd", gson.toJsonTree(cmd))
        }

        val body = gson.toJson(json).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/containers/start")
            .withAuth()
            .post(body)
            .build()

        val response = containerClient.newCall(request).execute()
        if (!response.isSuccessful) {
            val err = response.body?.string() ?: response.code.toString()
            response.close()
            throw Exception("Failed to start container: $err")
        }
        response.close()
        Log.d(TAG, "Container started: $name")
    }

    fun stopContainer(name: String) {
        val json = JsonObject().apply { addProperty("name", name) }
        val body = gson.toJson(json).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/containers/stop")
            .withAuth()
            .post(body)
            .build()

        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            val err = response.body?.string() ?: response.code.toString()
            response.close()
            throw Exception("Failed to stop container: $err")
        }
        response.close()
        Log.d(TAG, "Container stopped: $name")
    }

    fun listContainers(): List<Map<String, Any>> {
        return try {
            val request = Request.Builder()
                .url("$baseUrl/containers")
                .withAuth()
                .get()
                .build()

            val response = client.newCall(request).execute()
            if (!response.isSuccessful) {
                response.close()
                return emptyList()
            }

            val json = response.body?.string() ?: "[]"
            response.close()

            @Suppress("UNCHECKED_CAST")
            gson.fromJson(json, List::class.java) as? List<Map<String, Any>> ?: emptyList()
        } catch (e: Exception) {
            Log.e(TAG, "Error listing containers: ${e.message}")
            emptyList()
        }
    }

    fun vmExec(cmd: String): Map<String, Any> {
        val json = JsonObject().apply { addProperty("cmd", cmd) }
        val body = gson.toJson(json).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/vm/exec")
            .withAuth()
            .post(body)
            .build()

        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            val err = response.body?.string() ?: response.code.toString()
            response.close()
            throw Exception("VM exec failed: $err")
        }
        val jsonStr = response.body?.string() ?: "{}"
        response.close()
        @Suppress("UNCHECKED_CAST")
        return gson.fromJson(jsonStr, Map::class.java) as Map<String, Any>
    }

    fun getLogs(name: String, tail: Int): String {
        return try {
            val request = Request.Builder()
                .url("$baseUrl/logs?name=$name&tail=$tail")
                .withAuth()
                .get()
                .build()

            val response = client.newCall(request).execute()
            val logs = if (response.isSuccessful) response.body?.string() ?: "" else ""
            response.close()
            logs
        } catch (e: Exception) {
            Log.e(TAG, "Error getting logs: ${e.message}")
            ""
        }
    }
}

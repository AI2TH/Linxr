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

    // docker pull & run for mobile TCG emulation (supports large 5.5GB images like Ollama that take 30min+)
    private val containerClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(2400, TimeUnit.SECONDS) // 40 minutes timeout for heavy downloads/extractions
        .writeTimeout(60, TimeUnit.SECONDS)
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

    fun startContainer(
        image: String,
        name: String,
        cmd: List<String>,
        ports: List<Map<String, Any>> = emptyList(),
        env: List<Map<String, String>> = emptyList(),
        network: String = "host"
    ) {
        val json = JsonObject().apply {
            addProperty("image", image)
            addProperty("name", name)
            add("cmd", gson.toJsonTree(cmd))
            if (ports.isNotEmpty()) {
                add("ports", gson.toJsonTree(ports))
            }
            if (env.isNotEmpty()) {
                add("env", gson.toJsonTree(env))
            }
            addProperty("network", network)
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

        val response = containerClient.newCall(request).execute()
        if (!response.isSuccessful) {
            val err = response.body?.string() ?: response.code.toString()
            response.close()
            throw Exception("VM exec failed: $err")
        }
        val jsonStr = response.body?.string() ?: "{}"
        response.close()
        val jsonObject = com.google.gson.JsonParser.parseString(jsonStr).asJsonObject
        val result = mutableMapOf<String, Any>()
        if (jsonObject.has("stdout") && !jsonObject.get("stdout").isJsonNull) {
            result["stdout"] = jsonObject.get("stdout").asString
        }
        if (jsonObject.has("stderr") && !jsonObject.get("stderr").isJsonNull) {
            result["stderr"] = jsonObject.get("stderr").asString
        }
        if (jsonObject.has("exitCode") && !jsonObject.get("exitCode").isJsonNull) {
            result["exitCode"] = jsonObject.get("exitCode").asInt
        }
        return result
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

    // ── Container lifecycle ─────────────────────────────────────────────────

    fun startExistingContainer(name: String) {
        postJson("containers/start-existing", mapOf("name" to name))
    }

    fun restartContainer(name: String) {
        postJson("containers/restart", mapOf("name" to name))
    }

    fun deleteContainer(name: String) {
        postJson("containers/delete", mapOf("name" to name))
    }

    fun updateContainer(
        name: String,
        restartPolicy: String?,
        memoryMb: Long?,
        cpus: Double?
    ) {
        val body = mutableMapOf<String, Any>("name" to name)
        restartPolicy?.let { body["restartPolicy"] = it }
        memoryMb?.let { body["memoryMb"] = it }
        cpus?.let { body["cpus"] = it }
        postJson("containers/update", body)
    }

    fun inspectContainer(name: String): Map<String, Any> {
        return try {
            val encoded = java.net.URLEncoder.encode(name, "UTF-8")
            val request = Request.Builder()
                .url("$baseUrl/containers/inspect?name=$encoded")
                .withAuth()
                .get()
                .build()
            val response = client.newCall(request).execute()
            val json = response.body?.string() ?: "{}"
            response.close()
            if (!response.isSuccessful) throw Exception(json)
            @Suppress("UNCHECKED_CAST")
            (gson.fromJson(json, Map::class.java) as? Map<String, Any>) ?: emptyMap()
        } catch (e: Exception) {
            Log.e(TAG, "Error inspecting container: ${e.message}")
            throw e
        }
    }

    // ── Container export/import (snapshot tar) ──────────────────────────────

    fun exportContainer(name: String): String {
        return postJsonForField("containers/export", mapOf("name" to name), "file")
    }

    fun importContainer(name: String, file: String): String {
        return postJsonForField("containers/import", mapOf("name" to name, "file" to file), "output")
    }

    // ── Image save/load ─────────────────────────────────────────────────────

    fun saveImage(image: String): String {
        return postJsonForField("images/save", mapOf("image" to image), "file")
    }

    fun loadImage(file: String): String {
        return postJsonForField("images/load", mapOf("file" to file), "output")
    }

    fun listImages(): List<Map<String, Any>> {
        return try {
            val request = Request.Builder()
                .url("$baseUrl/images")
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
            Log.e(TAG, "Error listing images: ${e.message}")
            emptyList()
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private fun postJson(path: String, body: Map<String, Any>) {
        val json = gson.toJson(body).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/$path")
            .withAuth()
            .post(json)
            .build()
        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            val err = response.body?.string() ?: response.code.toString()
            response.close()
            throw Exception((err).take(300))
        }
        response.close()
        Log.d(TAG, "POST /$path ok")
    }

    private fun postJsonForField(path: String, body: Map<String, Any>, field: String): String {
        val json = gson.toJson(body).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/$path")
            .withAuth()
            .post(json)
            .build()
        val response = containerClient.newCall(request).execute()
        val jsonStr = response.body?.string() ?: "{}"
        response.close()
        if (!response.isSuccessful) throw Exception(jsonStr.take(300))
        val obj = try { com.google.gson.JsonParser.parseString(jsonStr).asJsonObject } catch (e: Exception) { com.google.gson.JsonObject() }
        return if (obj.has(field) && !obj.get(field).isJsonNull) obj.get(field).asString else ""
    }

    // ── Dual-Mode Container Engine ──────────────────────────────────────────

    fun getContainerEngine(): Map<String, Any> {
        return try {
            val request = Request.Builder()
                .url("$baseUrl/engine")
                .withAuth()
                .get()
                .build()
            val response = client.newCall(request).execute()
            val json = response.body?.string() ?: "{}"
            response.close()
            @Suppress("UNCHECKED_CAST")
            (gson.fromJson(json, Map::class.java) as? Map<String, Any>) ?: emptyMap()
        } catch (e: Exception) {
            Log.e(TAG, "getContainerEngine: ${e.message}")
            mapOf("mode" to "fasttrack", "error" to (e.message ?: "error"))
        }
    }

    fun setContainerEngine(mode: String): Map<String, Any> {
        val body = mapOf("mode" to mode)
        val json = gson.toJson(body).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/engine")
            .withAuth()
            .post(json)
            .build()
        val response = client.newCall(request).execute()
        val jsonStr = response.body?.string() ?: "{}"
        response.close()
        if (!response.isSuccessful) throw Exception(jsonStr.take(300))
        @Suppress("UNCHECKED_CAST")
        return (gson.fromJson(jsonStr, Map::class.java) as? Map<String, Any>) ?: emptyMap()
    }

    // ── Virtual Desktop (GUI) ────────────────────────────────────────────────

    fun getDesktopStatus(): Map<String, Any> {
        return try {
            val request = Request.Builder()
                .url("$baseUrl/desktop/status")
                .withAuth()
                .get()
                .build()
            val response = client.newCall(request).execute()
            val json = response.body?.string() ?: "{}"
            response.close()
            @Suppress("UNCHECKED_CAST")
            (gson.fromJson(json, Map::class.java) as? Map<String, Any>) ?: emptyMap()
        } catch (e: Exception) {
            Log.e(TAG, "getDesktopStatus: ${e.message}")
            mapOf("running" to false, "installed" to false, "error" to (e.message ?: "error"))
        }
    }

    fun startDesktop(resolution: String, wm: String): Map<String, Any> {
        val body = mapOf("resolution" to resolution, "wm" to wm)
        val json = gson.toJson(body).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/desktop/start")
            .withAuth()
            .post(json)
            .build()
        val response = containerClient.newCall(request).execute()
        val jsonStr = response.body?.string() ?: "{}"
        response.close()
        if (!response.isSuccessful) throw Exception(jsonStr.take(300))
        @Suppress("UNCHECKED_CAST")
        return (gson.fromJson(jsonStr, Map::class.java) as? Map<String, Any>) ?: emptyMap()
    }

    fun stopDesktop(): Map<String, Any> {
        val body = emptyMap<String, String>()
        val json = gson.toJson(body).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/desktop/stop")
            .withAuth()
            .post(json)
            .build()
        val response = client.newCall(request).execute()
        val jsonStr = response.body?.string() ?: "{}"
        response.close()
        if (!response.isSuccessful) throw Exception(jsonStr.take(300))
        @Suppress("UNCHECKED_CAST")
        return (gson.fromJson(jsonStr, Map::class.java) as? Map<String, Any>) ?: emptyMap()
    }

    fun installDesktop(mode: String): Map<String, Any> {
        val body = mapOf("mode" to mode)
        val json = gson.toJson(body).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/desktop/install")
            .withAuth()
            .post(json)
            .build()
        val response = containerClient.newCall(request).execute()
        val jsonStr = response.body?.string() ?: "{}"
        response.close()
        if (!response.isSuccessful) throw Exception(jsonStr.take(300))
        @Suppress("UNCHECKED_CAST")
        return (gson.fromJson(jsonStr, Map::class.java) as? Map<String, Any>) ?: emptyMap()
    }

    fun launchDesktopApp(app: String): Map<String, Any> {
        val body = mapOf("app" to app)
        val json = gson.toJson(body).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl/desktop/app")
            .withAuth()
            .post(json)
            .build()
        val response = client.newCall(request).execute()
        val jsonStr = response.body?.string() ?: "{}"
        response.close()
        if (!response.isSuccessful) throw Exception(jsonStr.take(300))
        @Suppress("UNCHECKED_CAST")
        return (gson.fromJson(jsonStr, Map::class.java) as? Map<String, Any>) ?: emptyMap()
    }
}

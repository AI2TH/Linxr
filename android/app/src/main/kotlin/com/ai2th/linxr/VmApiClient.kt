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
                .url("$baseUrl/logs?name=${java.net.URLEncoder.encode(name, "UTF-8")}&tail=$tail")
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

    // ── System ──────────────────────────────────────────────────────────────

    /** Alpine and kernel versions inside the VM (/etc/linxr-release). */
    fun getSystemRelease(): Map<String, Any> {
        val request = Request.Builder()
            .url("$baseUrl/system/release")
            .withAuth()
            .get()
            .build()
        val response = client.newCall(request).execute()
        val json = response.body?.string() ?: "{}"
        response.close()
        if (!response.isSuccessful) throw Exception(json.take(300))
        @Suppress("UNCHECKED_CAST")
        return (gson.fromJson(json, Map::class.java) as? Map<String, Any>) ?: emptyMap()
    }

    // ── SSH ─────────────────────────────────────────────────────────────────

    /**
     * Creates a new SSH key pair for the app inside the VM. The guest adds
     * the public key to /root/.ssh/authorized_keys and returns the private key
     * (OpenSSH format) without keeping a copy.
     */
    fun createAppSshKey(): String = postJsonForField("ssh/app-key", emptyMap(), "privateKey")

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

    // /desktop/start blocks until every desktop component is up or one has
    // failed; the guest gives up after 180 s (300 s hard limit in the API).
    private val desktopClient = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(330, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    /** The API's {"detail": ...} message, or the raw body if it has none. */
    private fun desktopError(jsonStr: String, code: Int): Exception {
        val detail = runCatching {
            gson.fromJson(jsonStr, JsonObject::class.java)?.get("detail")?.asString
        }.getOrNull()
        return Exception(detail?.takeIf { it.isNotBlank() } ?: "HTTP $code: ${jsonStr.take(300)}")
    }

    private fun desktopPost(path: String, body: Map<String, String>, http: OkHttpClient = desktopClient): Map<String, Any> {
        val json = gson.toJson(body).toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$baseUrl$path")
            .withAuth()
            .post(json)
            .build()
        http.newCall(request).execute().use { response ->
            val jsonStr = response.body?.string() ?: "{}"
            if (!response.isSuccessful) throw desktopError(jsonStr, response.code)
            @Suppress("UNCHECKED_CAST")
            return (gson.fromJson(jsonStr, Map::class.java) as? Map<String, Any>) ?: emptyMap()
        }
    }

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

    fun startDesktop(resolution: String, wm: String): Map<String, Any> =
        desktopPost("/desktop/start", mapOf("resolution" to resolution, "wm" to wm))

    fun stopDesktop(): Map<String, Any> = desktopPost("/desktop/stop", emptyMap())

    /** Starts the install in the guest and returns at once (HTTP 202); poll getDesktopStatus(). */
    fun installDesktop(mode: String): Map<String, Any> =
        desktopPost("/desktop/install", mapOf("mode" to mode))

    fun launchDesktopApp(app: String): Map<String, Any> =
        desktopPost("/desktop/app", mapOf("app" to app), client)

    /** Plain-text desktop log; name "all" combines every component log. */
    fun getDesktopLog(name: String, lines: Int): String {
        val request = Request.Builder()
            .url("$baseUrl/desktop/log?name=${java.net.URLEncoder.encode(name, "UTF-8")}&lines=$lines")
            .withAuth()
            .get()
            .build()
        client.newCall(request).execute().use { response ->
            val text = response.body?.string() ?: ""
            if (!response.isSuccessful) throw desktopError(text, response.code)
            return text
        }
    }
}

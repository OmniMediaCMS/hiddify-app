package com.hiddify.hiddify.tor

import android.content.Context
import android.util.Log
import androidx.lifecycle.MutableLiveData
import dalvik.system.DexClassLoader
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject

object TorProcessManager {
    private const val TAG = "A/TorProcessManager"
    private val startExecutor = Executors.newCachedThreadPool()
    private val stopExecutor = Executors.newSingleThreadExecutor()
    private var process: Process? = null
    private var readerThread: Thread? = null
    private var transportRuntime: IptProxyRuntime? = null
    private var bootstrapPercent = 0
    private var summary = "Disabled"

    val status = MutableLiveData(statusMap(TorStatus.Disabled, 0, "Disabled"))

    fun start(context: Context, config: TorConfig) {
        startExecutor.execute {
            Log.d(TAG, "start requested")
            resetStaleStateBeforeStart()
            Log.d(TAG, "stale state reset")
            publish(TorStatus.Starting, 0, "Starting Tor")

            if (!isPortOpen("127.0.0.1", config.upstreamSocksPort)) {
                publish(
                    TorStatus.Failed,
                    0,
                    "Tor upstream SOCKS 127.0.0.1:${config.upstreamSocksPort} is not ready",
                )
                return@execute
            }

            val nativeDir = context.applicationInfo.nativeLibraryDir
            val torBinary = File(nativeDir, "libtor.so")
            if (!torBinary.exists()) {
                publish(TorStatus.Failed, 0, "Tor binary not found")
                return@execute
            }

            val torDir = File(context.filesDir, "tor").also { it.mkdirs() }
            val dataDir = File(torDir, "data").also { it.mkdirs() }
            val bridgeMode = config.bridgeMode.lowercase()
            Log.d(TAG, "starting transport mode: $bridgeMode")

            val transport = try {
                startTransportIfNeeded(context, torDir, bridgeMode, config.upstreamSocksPort)
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "failed to load pluggable transport library", e)
                publish(TorStatus.Failed, 0, e.message ?: "Transport native library failed")
                return@execute
            } catch (e: Exception) {
                publish(TorStatus.Failed, 0, e.message ?: "Transport failed")
                return@execute
            }
            Log.d(TAG, "transport ready: ${transport.localAddress}")

            val torrc = File(torDir, "torrc")
            torrc.writeText(buildTorrc(context, config, dataDir, transport))
            Log.d(TAG, "starting tor process")

            try {
                val builder = ProcessBuilder(torBinary.absolutePath, "-f", torrc.absolutePath)
                    .redirectErrorStream(true)
                builder.environment()["HOME"] = torDir.absolutePath
                builder.environment()["TOR_PT_PROXY"] = "socks5://127.0.0.1:${config.upstreamSocksPort}"
                val running = builder.start()
                process = running
                Log.d(TAG, "tor process started")
                readerThread = Thread({ readTorOutput(running) }, "TorLogReader").also {
                    it.isDaemon = true
                    it.start()
                }
            } catch (e: Exception) {
                Log.e(TAG, "failed to start Tor", e)
                publish(TorStatus.Failed, bootstrapPercent, e.message ?: "Failed to start Tor")
            }
        }
    }

    private fun resetStaleStateBeforeStart() {
        process = null
        readerThread = null
        bootstrapPercent = 0
        summary = "Disabled"
    }

    fun stop() {
        stopExecutor.execute {
            stopInternal(publishStopping = true)
        }
    }

    fun stopBlocking(timeoutMillis: Long = 4000L) {
        val done = CountDownLatch(1)
        stopExecutor.execute {
            try {
                stopInternal(publishStopping = true)
            } finally {
                done.countDown()
            }
        }
        if (!done.await(timeoutMillis, TimeUnit.MILLISECONDS)) {
            Log.w(TAG, "timed out waiting for Tor to stop")
        }
    }

    private fun stopInternal(publishStopping: Boolean) {
        Log.d(TAG, "stop requested")
        if (publishStopping) publish(TorStatus.Stopping, bootstrapPercent, "Stopping Tor")
        val running = process
        process = null
        running?.destroy()
        readerThread?.interrupt()
        readerThread = null
        try {
            if (running != null && !running.waitFor(1500, TimeUnit.MILLISECONDS)) {
                running.destroyForcibly()
                running.waitFor(1500, TimeUnit.MILLISECONDS)
            }
        } catch (e: Exception) {
            Log.w(TAG, "failed while stopping Tor process", e)
        }
        bootstrapPercent = 0
        summary = "Disabled"
        publish(TorStatus.Disabled, 0, "Disabled")
    }

    private fun readTorOutput(running: Process) {
        try {
            running.inputStream.bufferedReader().useLines { lines ->
                lines.forEach { line ->
                    Log.d(TAG, line)
                    handleLogLine(line)
                }
            }
            if (process === running) {
                publish(TorStatus.Failed, bootstrapPercent, "Tor process exited")
            }
        } catch (e: Exception) {
            if (process === running) {
                publish(TorStatus.Failed, bootstrapPercent, "Tor log reader failed")
            }
        }
    }

    private fun handleLogLine(line: String) {
        val marker = "Bootstrapped "
        val index = line.indexOf(marker)
        if (index >= 0) {
            val rest = line.substring(index + marker.length)
            val percent = rest.substringBefore("%").toIntOrNull() ?: bootstrapPercent
            bootstrapPercent = percent.coerceIn(0, 100)
            summary = rest.substringAfter("%", "").trim().ifBlank { line }
            if (bootstrapPercent >= 100) {
                publish(TorStatus.Ready, bootstrapPercent, summary)
            } else {
                publish(TorStatus.Bootstrapping, bootstrapPercent, summary)
            }
            return
        }

        if (line.contains("[err]", ignoreCase = true)) {
            summary = line
            publish(TorStatus.Failed, bootstrapPercent, summary)
        }
    }

    private fun buildTorrc(
        context: Context,
        config: TorConfig,
        dataDir: File,
        transport: TransportPlugin,
    ): String {
        val mode = config.bridgeMode.lowercase()
        val bridges = effectiveBridges(context, mode, config.customBridges)
        val builder = StringBuilder()
        builder.appendLine("SocksPort 127.0.0.1:${config.socksPort}")
        builder.appendLine("ControlPort 127.0.0.1:${config.controlPort}")
        builder.appendLine("CookieAuthentication 1")
        builder.appendLine("DataDirectory ${dataDir.absolutePath}")
        builder.appendLine("ClientOnly 1")
        builder.appendLine("AvoidDiskWrites 1")
        builder.appendLine("Log notice stdout")
        if (mode == "direct" || !transport.required) {
            builder.appendLine("Socks5Proxy 127.0.0.1:${config.upstreamSocksPort}")
        }

        if (mode != "direct") {
            builder.appendLine("UseBridges 1")
            if (transport.required) {
                builder.appendLine("ClientTransportPlugin ${transport.torTransportName} socks5 ${transport.localAddress}")
            }
            bridges.forEach { builder.appendLine("Bridge $it") }
        }

        return builder.toString()
    }

    private fun startTransportIfNeeded(
        context: Context,
        torDir: File,
        mode: String,
        upstreamSocksPort: Int,
    ): TransportPlugin {
        return when (mode) {
            "obfs4" -> {
                startIptProxyTransport(context, torDir, "Obfs4", "obfs4", upstreamSocksPort)
            }
            "snowflake" -> {
                startIptProxyTransport(context, torDir, "Snowflake", "snowflake", upstreamSocksPort, useProxy = false)
            }
            "meek" -> {
                startIptProxyTransport(context, torDir, "MeekLite", "meek_lite", upstreamSocksPort)
            }
            else -> TransportPlugin(required = false, torTransportName = "", localAddress = "")
        }
    }

    private fun startIptProxyTransport(
        context: Context,
        torDir: File,
        iptTransportField: String,
        torTransportName: String,
        upstreamSocksPort: Int,
        useProxy: Boolean = true,
    ): TransportPlugin {
        val stateDir = File(torDir, "pt-state").also { it.mkdirs() }
        transportRuntime?.let { runtime ->
            val iptTransportName = runtime.transportName(iptTransportField)
            val localAddress = runtime.localAddress(iptTransportName)
            if (localAddress.isNotBlank()) {
                Log.d(TAG, "reusing transport $torTransportName at $localAddress")
                return TransportPlugin(
                    required = true,
                    torTransportName = torTransportName,
                    localAddress = localAddress,
                )
            }
        }
        val runtime = IptProxyRuntime.create(
            context = context,
            stateDir = stateDir,
            proxyUrl = if (useProxy) "socks5://127.0.0.1:$upstreamSocksPort" else "",
        )
        val iptTransportName = runtime.transportName(iptTransportField)
        runtime.start(iptTransportName)
        val localAddress = runtime.localAddress(iptTransportName)
        if (localAddress.isBlank()) {
            runtime.stop()
            throw IllegalStateException("$torTransportName transport did not provide a local address")
        }
        transportRuntime = runtime
        return TransportPlugin(
            required = true,
            torTransportName = torTransportName,
            localAddress = localAddress,
        )
    }

    private fun effectiveBridges(context: Context, mode: String, customBridges: List<String>): List<String> {
        val cleanedCustom = customBridges.map { it.trim() }.filter { it.isNotEmpty() }
        if (cleanedCustom.isNotEmpty()) return cleanedCustom
        orbotBuiltinBridges(context, mode).takeIf { it.isNotEmpty() }?.let { return it }
        return when (mode) {
            "obfs4" -> listOf(
                "obfs4 209.148.46.65:443 74FAD13168806246602538555B5521A0383A1875 cert=ssH+9rP8dG2NLDN2XuFw63hIO/9MNNinLmxQDpVa+7kTOa9/m+tGWT1SmSYpQ9uTBGa6Hw iat-mode=0",
                "obfs4 212.83.43.74:443 39562501228A4D5E27FCA4C0C81A01EE23AE3EE4 cert=PBwr+S8JTVZo6MPdHnkTwXJPILWADLqfMGoVvhZClMq/Urndyd42BwX9YFJHZnBB3H0XCw iat-mode=1",
                "obfs4 51.222.13.177:80 5EDAC3B810E12B01F6FD8050D2FD3E277B289A08 cert=2uplIpLQ0q9+0qMFrK5pkaYRDOe460LL9WHBvatgkuRr/SL31wBOEupaMMJ6koRE6Ld0ew iat-mode=0",
            )
            "snowflake" -> listOf("snowflake 192.0.2.3:1")
            "meek" -> listOf("meek_lite 0.0.2.0:1 url=https://meek.azureedge.net/ front=ajax.aspnetcdn.com")
            else -> emptyList()
        }
    }

    private fun orbotBuiltinBridges(context: Context, mode: String): List<String> {
        val key = when (mode) {
            "meek" -> "meek"
            else -> mode
        }
        return runCatching {
            val json = context.assets.open("tor/builtin-bridges.json")
                .bufferedReader()
                .use { it.readText() }
            val array = JSONObject(json).optJSONArray(key) ?: return emptyList()
            buildList {
                for (index in 0 until array.length()) {
                    array.optString(index).trim().takeIf { it.isNotEmpty() }?.let(::add)
                }
            }
        }.getOrElse { error ->
            Log.w(TAG, "failed to load Orbot builtin bridges for $mode", error)
            emptyList()
        }
    }

    private fun isPortOpen(host: String, port: Int): Boolean {
        return try {
            Socket().use {
                it.connect(InetSocketAddress(host, port), 500)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun publish(nextStatus: TorStatus, percent: Int, nextSummary: String) {
        bootstrapPercent = percent.coerceIn(0, 100)
        summary = nextSummary
        status.postValue(statusMap(nextStatus, bootstrapPercent, summary))
    }

    private data class TransportPlugin(
        val required: Boolean,
        val torTransportName: String,
        val localAddress: String,
    )

    private class IptProxyRuntime private constructor(
        private val controller: Any,
        private val controllerClass: Class<*>,
        private val proxyUrl: String,
        private var runningTransport: String?,
    ) {
        fun transportName(fieldName: String): String {
            return iptProxyClass.getField(fieldName).get(null) as String
        }

        fun start(transport: String) {
            controllerClass.getMethod("start", String::class.java, String::class.java)
                .invoke(controller, transport, proxyUrl)
            runningTransport = transport
        }

        fun localAddress(transport: String): String {
            return controllerClass.getMethod("localAddress", String::class.java)
                .invoke(controller, transport) as String
        }

        fun stop() {
            val transport = runningTransport ?: return
            runCatching {
                controllerClass.getMethod("stop", String::class.java).invoke(controller, transport)
            }
            runningTransport = null
        }

        companion object {
            private lateinit var iptProxyClass: Class<*>
            private var cachedClassLoader: DexClassLoader? = null

            fun create(context: Context, stateDir: File, proxyUrl: String): IptProxyRuntime {
                val loader = classLoader(context)
                iptProxyClass = loader.loadClass("IPtProxy.IPtProxy")
                val eventsClass = loader.loadClass("IPtProxy.OnTransportEvents")
                val events = Proxy.newProxyInstance(loader, arrayOf(eventsClass)) { _, method, args ->
                    val transport = args?.getOrNull(0) as? String ?: ""
                    when (method.name) {
                        "connected" -> Log.d(TAG, "transport connected: $transport")
                        "error" -> Log.e(TAG, "transport error: $transport", args?.getOrNull(1) as? Exception)
                        "stopped" -> {
                            val error = args?.getOrNull(1) as? Exception
                            if (error != null) {
                                Log.e(TAG, "transport stopped: $transport", error)
                            } else {
                                Log.d(TAG, "transport stopped: $transport")
                            }
                        }
                    }
                    null
                }
                val controller = iptProxyClass.getMethod(
                    "newController",
                    String::class.java,
                    Boolean::class.javaPrimitiveType,
                    Boolean::class.javaPrimitiveType,
                    String::class.java,
                    eventsClass,
                ).invoke(null, stateDir.absolutePath, true, false, "ERROR", events)
                return IptProxyRuntime(controller, controller.javaClass, proxyUrl, null)
            }

            private fun classLoader(context: Context): DexClassLoader {
                cachedClassLoader?.let { return it }
                val runtimeDir = File(context.codeCacheDir, "iptproxy").also { it.mkdirs() }
                val jarFile = File(runtimeDir, "classes.jar")
                if (!jarFile.exists()) {
                    context.assets.open("iptproxy/classes.jar").use { input ->
                        jarFile.outputStream().use { output -> input.copyTo(output) }
                    }
                    jarFile.setReadable(true, false)
                    jarFile.setWritable(false, false)
                }
                val optimizedDir = File(runtimeDir, "optimized").also { it.mkdirs() }
                val bootParent = TorProcessManager::class.java.classLoader?.parent
                return DexClassLoader(
                    jarFile.absolutePath,
                    optimizedDir.absolutePath,
                    context.applicationInfo.nativeLibraryDir,
                    bootParent,
                ).also { cachedClassLoader = it }
            }
        }
    }

    private fun statusMap(status: TorStatus, percent: Int, summary: String): Map<String, Any> {
        return mapOf(
            "status" to status.name,
            "bootstrapPercent" to percent,
            "summary" to summary,
        )
    }
}

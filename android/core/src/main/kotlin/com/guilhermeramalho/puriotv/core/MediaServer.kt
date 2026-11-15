package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID

/** The byte range a request asks for, resolved against the size (ByteRange in MediaServer.swift). */
data class ByteRange(val start: Long, val end: Long) {
    val length: Long get() = end - start + 1
    companion object {
        /** null header → the whole file; null result → unsatisfiable (416). */
        fun resolve(header: String?, size: Long): ByteRange? {
            if (size <= 0) return null
            val h = header?.trim().orEmpty()
            if (h.isEmpty()) return ByteRange(0, size - 1)
            if (!h.lowercase().startsWith("bytes=") || h.contains(',')) return null
            val spec = h.substring(6).split("-", limit = 2).map { it.trim() }
            if (spec.size != 2) return null
            if (spec[0].isEmpty()) {
                val suffix = spec[1].toLongOrNull() ?: return null
                if (suffix <= 0) return null
                return ByteRange(maxOf(0, size - suffix), size - 1)
            }
            val start = spec[0].toLongOrNull() ?: return null
            if (start < 0 || start >= size) return null
            val end = if (spec[1].isEmpty()) size - 1 else minOf(spec[1].toLongOrNull() ?: -1, size - 1)
            return if (end >= start) ByteRange(start, end) else null
        }
    }
}

data class HttpRequestHead(val method: String, val path: String, val headers: Map<String, String>) {
    companion object {
        /** Reads up to the blank line that ends the head (at most 16 KB); null if it never comes. */
        fun read(input: InputStream): HttpRequestHead? {
            val bytes = java.io.ByteArrayOutputStream()
            var last4 = 0
            while (bytes.size() < 16384) {
                val b = input.read()
                if (b < 0) return null
                bytes.write(b)
                last4 = (last4 shl 8) or b
                if (last4 == 0x0d0a0d0a) return parse(bytes.toString(Charsets.UTF_8))
            }
            return null
        }
        fun parse(text: String): HttpRequestHead {
            val lines = text.split("\r\n")
            val first = lines.firstOrNull()?.split(' ') ?: emptyList()
            val headers = mutableMapOf<String, String>()
            for (line in lines.drop(1)) {
                val colon = line.indexOf(':')
                if (colon > 0) headers[line.substring(0, colon).lowercase()] = line.substring(colon + 1).trim()
            }
            return HttpRequestHead(first.getOrElse(0) { "" }, first.getOrElse(1) { "" }, headers)
        }
    }
}

/**
 * Serves the item on the TV to its player over the home network, only while Show on TV is open (MediaServer.swift).
 * Each item gets a random path; anything else gets 404. Files are read in 64 KB chunks as the player asks.
 * Items can be files or content the app opens on demand ([Source]), so videos stream straight from MediaStore.
 */
class MediaServer {
    /** Something the server can send: its size and a way to read it from an offset. */
    interface Source { val size: Long; val contentType: String; fun open(offset: Long): InputStream }
    class FileSource(private val file: File, override val contentType: String) : Source {
        override val size: Long get() = file.length()
        override fun open(offset: Long): InputStream = file.inputStream().also { it.skip(offset) }
    }

    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var server: ServerSocket? = null
    private val items = LinkedHashMap<String, Source>()
    /** Called for each request: method, whether the path is shared, the range asked. */
    @Volatile var requestLog: ((String, Boolean, String?) -> Unit)? = null
    val port: Int? get() = server?.localPort

    /** Starts listening (once) and returns the port. */
    @Synchronized fun start(): Int {
        server?.let { return it.localPort }
        val socket = ServerSocket(0)
        server = socket
        io.launch {
            while (isActive) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                io.launch { serve(client) }
            }
        }
        return socket.localPort
    }

    /** Makes [source] reachable and returns its path ("/<random>/<name>"); only the newest [keep] stay shared. */
    @Synchronized fun share(source: Source, name: String, keep: Int = 3): String {
        val token = UUID.randomUUID().toString().replace("-", "")
        val path = "/$token/" + java.net.URLEncoder.encode(name, "UTF-8").replace("+", "%20")
        items[path] = source
        while (items.size > keep) items.remove(items.keys.first())
        return path
    }

    @Synchronized fun stop() {
        runCatching { server?.close() }
        server = null
        items.clear()
    }
    fun close() { stop(); io.cancel() }

    private fun serve(client: Socket) = client.use { socket ->
        socket.soTimeout = 120_000
        val head = HttpRequestHead.read(socket.getInputStream()) ?: return
        val out = socket.getOutputStream()
        if (head.method != "GET" && head.method != "HEAD") { out.write(status("405 Method Not Allowed")); return }
        val source = synchronized(this) { items[head.path] }
        requestLog?.invoke(head.method, source != null, head.headers["range"])
        if (source == null) { out.write(status("404 Not Found")); return }
        val asked = head.headers["range"]
        val range = ByteRange.resolve(asked, source.size)
            ?: run { out.write(status("416 Range Not Satisfiable", "Content-Range: bytes */${source.size}\r\n")); return }
        val response = StringBuilder(if (asked == null) "HTTP/1.1 200 OK\r\n" else "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes ${range.start}-${range.end}/${source.size}\r\n")
        response.append("Content-Type: ${source.contentType}\r\nContent-Length: ${range.length}\r\nAccept-Ranges: bytes\r\n")
        response.append("Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
        out.write(response.toString().toByteArray())
        if (head.method == "HEAD") return
        source.open(range.start).use { input ->
            val chunk = ByteArray(65536)
            var left = range.length
            while (left > 0) {
                val n = input.read(chunk, 0, minOf(chunk.size.toLong(), left).toInt())
                if (n < 0) break
                out.write(chunk, 0, n)
                left -= n
            }
        }
        out.flush()
    }
    private fun status(line: String, extra: String = "") =
        "HTTP/1.1 $line\r\n${extra}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray()
}

/** This phone's IPv4 address as the TV can reach it: on the TV's subnet, else the Wi-Fi one (LocalAddress.swift). */
object LocalAddress {
    data class Interface(val name: String, val address: String, val prefixLength: Int)

    fun pick(tvHost: String, interfaces: List<Interface>): String? {
        val usable = interfaces.filter { !it.address.startsWith("127.") && !it.address.startsWith("169.254.") }
        val tv = ipv4(tvHost)
        if (tv != null) usable.firstOrNull { i ->
            val address = ipv4(i.address) ?: return@firstOrNull false
            val mask = if (i.prefixLength == 0) 0L else (0xffffffffL shl (32 - i.prefixLength)) and 0xffffffffL
            address and mask == tv and mask
        }?.let { return it.address }
        return usable.firstOrNull { it.name.startsWith("wlan") }?.address
    }
    fun current(tvHost: String): String? = pick(tvHost, interfaces())

    internal fun ipv4(text: String): Long? {
        val parts = text.split('.').mapNotNull { it.toLongOrNull() }
        if (parts.size != 4 || parts.any { it !in 0..255 }) return null
        return (parts[0] shl 24) or (parts[1] shl 16) or (parts[2] shl 8) or parts[3]
    }
    private fun interfaces(): List<Interface> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp }.flatMap { nif ->
            nif.interfaceAddresses.filter { it.address is Inet4Address }.map { Interface(nif.name, it.address.hostAddress ?: "", it.networkPrefixLength.toInt()) }
        }
    }.getOrDefault(emptyList())
}

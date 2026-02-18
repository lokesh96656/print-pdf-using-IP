package com.example.doc_print

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.graphics.Bitmap
import android.graphics.pdf.PdfDocument
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "doc_print/print"
        private const val TAG = "DocPrint"
        @Volatile private var PRINT_IN_PROGRESS: Boolean = false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "printPdfToPrinter") {
                val ip = call.argument<String>("ip") ?: ""
                val port = call.argument<Int>("port") ?: 631
                val ippPath = call.argument<String>("ippPath")?.takeIf { it.isNotEmpty() } ?: "/"
                val pdfPath = call.argument<String>("pdfPath") ?: ""
                if (ip.isEmpty() || pdfPath.isEmpty()) {
                    result.error("INVALID_ARGS", "ip and pdfPath required", null)
                    return@setMethodCallHandler
                }

                if (PRINT_IN_PROGRESS) {
                    result.error("PRINT_IN_PROGRESS", "Another print is already running. Please wait.", null)
                    return@setMethodCallHandler
                }
                PRINT_IN_PROGRESS = true

                // Printing does network I/O and must not run on the UI thread.
                Thread {
                    try {
                        Log.i(TAG, "Printing to $ip:$port$ippPath, pdfPath=$pdfPath")
                        printPdfToPrinter(ip, port, ippPath, pdfPath)
                        runOnUiThread { result.success(null) }
                    } catch (e: Exception) {
                        Log.e(TAG, "Print failed", e)
                        runOnUiThread { result.error("PRINT_FAILED", e.toString(), null) }
                    } finally {
                        PRINT_IN_PROGRESS = false
                    }
                }.start()
            } else {
                result.notImplemented()
            }
        }
    }

    private fun printPdfToPrinter(ip: String, port: Int, ippPath: String, pdfPath: String) {
        val path = ippPath.let { if (it.startsWith("/")) it else "/$it" }
        val printerUri = "ipp://$ip:$port$path"
        var requestId = (System.currentTimeMillis() and 0x7fffffff).toInt()

        // Single page: high quality, one Print-Job.
        // Multi-page: split into one Print-Job per page (image/jpeg), sent one-by-one in background with delay between pages.
        val isMultiPage = try {
            val pfd = openPdfForPageCount(pdfPath) ?: throw Exception("Cannot open PDF")
            try {
                PdfRenderer(pfd).use { it.pageCount > 1 }
            } finally {
                pfd.close()
            }
        } catch (_: Exception) {
            true
        }

        val jpegPages = renderPdfToJpegPages(pdfPath, multiPage = isMultiPage)
        if (jpegPages.isEmpty()) {
            throw Exception("Could not render PDF to images. Check that the file is a valid PDF.")
        }

        for (index in jpegPages.indices) {
            val jpegBytes = jpegPages[index]
            val jobName = if (jpegPages.size == 1) "doc_print" else "doc_print ${index + 1}/${jpegPages.size}"
            val printJobBody = buildIppPrintJobRequest(
                printerUri = printerUri,
                documentFormat = "image/jpeg",
                requestId = requestId,
                jobName = jobName,
            ) + jpegBytes
            val resp = sendIppRequestWithRetry(ip, port, path, printJobBody)
            checkIppResponse(resp)
            requestId += 1
            // Delay between pages so printer can finish before next job (reduces overload/empty response).
            if (index < jpegPages.size - 1) Thread.sleep(30000)
        }
    }

    private fun openPdfForPageCount(pdfPath: String): ParcelFileDescriptor? {
        val pdfBytes = try {
            readPdfBytes(pdfPath)
        } catch (_: Exception) {
            return null
        }
        if (pdfBytes.isEmpty()) return null
        val f = File(cacheDir, "doc_print_pc_${System.currentTimeMillis()}.pdf")
        f.writeBytes(pdfBytes)
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
        // Temp file left in cacheDir; system will clear when needed.
    }

    private data class FlattenedPdf(val pageCount: Int, val bytes: ByteArray)

    /** Render PDF pages and rebuild them into one image-based PDF (still multi-page). */
    private fun flattenPdfToPdfBytes(pdfPath: String): FlattenedPdf {
        val srcBytes = readPdfBytes(pdfPath)
        if (srcBytes.isEmpty()) throw Exception("Empty PDF")

        val inFile = File(cacheDir, "doc_print_in_${System.currentTimeMillis()}.pdf")
        val outFile = File(cacheDir, "doc_print_flat_${System.currentTimeMillis()}.pdf")

        try {
            inFile.writeBytes(srcBytes)
            val pfd = ParcelFileDescriptor.open(inFile, ParcelFileDescriptor.MODE_READ_ONLY)
            try {
                val renderer = PdfRenderer(pfd)
                val pageCount = renderer.pageCount
                val doc = PdfDocument()
                try {
                    val scale = 1.35f
                    for (i in 0 until pageCount) {
                        val page = renderer.openPage(i)
                        val w = (page.width * scale).toInt()
                        val h = (page.height * scale).toInt()
                        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                        page.close()

                        val pageInfo = PdfDocument.PageInfo.Builder(w, h, i + 1).create()
                        val outPage = doc.startPage(pageInfo)
                        outPage.canvas.drawBitmap(bmp, 0f, 0f, null)
                        doc.finishPage(outPage)
                        bmp.recycle()
                    }
                    FileOutputStream(outFile).use { fos -> doc.writeTo(fos) }
                } finally {
                    doc.close()
                }
                renderer.close()
                return FlattenedPdf(pageCount, outFile.readBytes())
            } finally {
                pfd.close()
            }
        } finally {
            try { inFile.delete() } catch (_: Exception) {}
            try { outFile.delete() } catch (_: Exception) {}
        }
    }

    /** Send IPP request; retry on busy (0x0507) and on invalid/short IPP responses. */
    private fun sendIppRequestWithRetry(
        ip: String,
        port: Int,
        path: String,
        requestBody: ByteArray,
        maxRetries: Int = 14,
    ): ByteArray {
        for (attempt in 0 until maxRetries) {
            val responseBody = sendIppRequest(ip, port, path, requestBody)

            // A valid IPP response must contain at least the 8-byte header.
            // Some printers return HTTP 200 but empty body when overloaded.
            if (responseBody.size < 8) {
                if (attempt >= maxRetries - 1) {
                    // One last attempt after a long pause
                    Log.i(TAG, "Short response after $maxRetries attempts; waiting 45s then one more try")
                    Thread.sleep(45000)
                    val last = sendIppRequest(ip, port, path, requestBody)
                    if (last.size >= 8) return last
                    throw Exception("Invalid IPP response (empty/short). Printer may be overloaded. Wait 1–2 minutes and try again.")
                }
                val waitMs = 5000L + (attempt * 3000L) // 5s, 8s, 11s, 14s, ...
                Log.i(TAG, "Short IPP response (${responseBody.size} bytes), attempt ${attempt + 1}/$maxRetries, waiting ${waitMs}ms")
                tryLogPrinterStatus(ip, port, path)
                Thread.sleep(waitMs)
                continue
            }

            val ippStatus = ((responseBody[2].toInt() and 0xFF) shl 8) or (responseBody[3].toInt() and 0xFF)
            when {
                ippStatus != 0x0507 -> return responseBody
                attempt >= maxRetries - 1 -> throw Exception("Printer busy. Cancel any stuck job on the printer, wait 1 minute, then try again.")
                else -> {
                    val waitMs = if (attempt == 0) 10000 else 8000 + (attempt * 2000)
                    Log.i(TAG, "Printer busy (0x0507), attempt ${attempt + 1}/$maxRetries, waiting ${waitMs}ms")
                    tryLogPrinterStatus(ip, port, path)
                    Thread.sleep(waitMs.toLong())
                }
            }
        }
        throw Exception("Printer busy. Wait a minute and try again.")
    }

    private data class PrinterStatus(
        val state: Int?,
        val acceptingJobs: Boolean?,
        val reasons: List<String>,
    )

    /** Best-effort: fetch printer-state / printer-is-accepting-jobs / printer-state-reasons for debugging. */
    private fun tryLogPrinterStatus(ip: String, port: Int, path: String) {
        try {
            val printerUri = "ipp://$ip:$port$path"
            val reqId = ((System.currentTimeMillis() and 0x7fffffff).toInt())
            val req = buildIppGetPrinterAttributesRequest(printerUri, reqId)
            val resp = sendIppRequest(ip, port, path, req)
            // Don't call checkIppResponse here; some printers return errors while busy.
            val status = parsePrinterStatus(resp)
            Log.i(TAG, "PrinterStatus: state=${status.state}, accepting=${status.acceptingJobs}, reasons=${status.reasons.joinToString()}")
        } catch (e: Exception) {
            Log.i(TAG, "PrinterStatus fetch failed: ${e.message}")
        }
    }

    private fun buildIppGetPrinterAttributesRequest(printerUri: String, requestId: Int): ByteArray {
        val out = ByteArrayOutputStream()
        writeIppHeader(out, operationId = 0x000B, requestId = requestId) // Get-Printer-Attributes
        out.write(0x01) // operation-attributes-tag
        appendAttr(out, 0x47, "attributes-charset", "utf-8")
        appendAttr(out, 0x48, "attributes-natural-language", "en-us")
        appendAttr(out, 0x45, "printer-uri", printerUri)
        appendAttr(out, 0x42, "requesting-user-name", "anonymous")
        // requested-attributes: printer-state, printer-is-accepting-jobs, printer-state-reasons
        appendAttr(out, 0x44, "requested-attributes", "printer-state")
        appendAdditionalValue(out, 0x44, "printer-is-accepting-jobs")
        appendAdditionalValue(out, 0x44, "printer-state-reasons")
        out.write(0x03)
        return out.toByteArray()
    }

    /** Adds an additional-value (name-length = 0) for a multi-valued attribute. */
    private fun appendAdditionalValue(out: ByteArrayOutputStream, valueTag: Int, value: String) {
        val valueBytes = value.toByteArray(StandardCharsets.UTF_8)
        out.write(valueTag)
        out.write(shortToBigEndian(0)) // name-length = 0 for additional-value
        out.write(shortToBigEndian(valueBytes.size))
        out.write(valueBytes)
    }

    private fun parsePrinterStatus(responseBody: ByteArray): PrinterStatus {
        var state: Int? = null
        var accepting: Boolean? = null
        val reasons = ArrayList<String>()
        for (a in scanIppAttributes(responseBody)) {
            when (a.name) {
                "printer-state" -> if ((a.tag == 0x23 || a.tag == 0x21) && a.value.size == 4) {
                    state = ((a.value[0].toInt() and 0xFF) shl 24) or
                        ((a.value[1].toInt() and 0xFF) shl 16) or
                        ((a.value[2].toInt() and 0xFF) shl 8) or
                        (a.value[3].toInt() and 0xFF)
                }
                "printer-is-accepting-jobs" -> if (a.tag == 0x22 && a.value.isNotEmpty()) {
                    accepting = (a.value[0].toInt() and 0xFF) != 0
                }
                "printer-state-reasons" -> if (a.tag == 0x44 && a.value.isNotEmpty()) {
                    reasons.add(String(a.value, StandardCharsets.UTF_8))
                }
            }
        }
        return PrinterStatus(state = state, acceptingJobs = accepting, reasons = reasons)
    }

    /** Renders PDF to one JPEG per page so the printer can render (not raw bytes). Uses a temp file so PdfRenderer always has a real file (works with content URIs and scoped storage). */
    private fun renderPdfToJpegPages(pdfPath: String, multiPage: Boolean): List<ByteArray> {
        val pdfBytes = try {
            readPdfBytes(pdfPath)
        } catch (_: Exception) {
            return emptyList()
        }
        if (pdfBytes.isEmpty()) return emptyList()
        val tempFile = File(cacheDir, "doc_print_temp_${System.currentTimeMillis()}.pdf")
        return try {
            tempFile.writeBytes(pdfBytes)
            val pfd = ParcelFileDescriptor.open(tempFile, ParcelFileDescriptor.MODE_READ_ONLY)
            try {
                val renderer = PdfRenderer(pfd)
                val pages = mutableListOf<ByteArray>()
                // Single page: higher quality (what was working).
                // Multi page: lower quality to avoid printers dropping big pages.
                // Multi-page prints need small per-page payloads; some printers silently drop large JPEG pages.
                val scale = if (multiPage) 1.10f else 2.0f
                val baseQuality = if (multiPage) 65 else 90
                val maxMultiPageBytes = 70_000
                for (i in 0 until renderer.pageCount) {
                    val page = renderer.openPage(i)
                    val width = (page.width * scale).toInt()
                    val height = (page.height * scale).toInt()
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    page.close()
                    // Adaptive JPEG compression for multi-page: keep each page under ~70KB when possible.
                    var quality = baseQuality
                    var bytes: ByteArray
                    while (true) {
                        val jpeg = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, jpeg)
                        bytes = jpeg.toByteArray()
                        if (!multiPage || bytes.size <= maxMultiPageBytes || quality <= 35) break
                        quality -= 10
                    }
                    bitmap.recycle()
                    Log.i(
                        TAG,
                        "Rendered page ${i + 1}/${renderer.pageCount}: ${width}x${height}, jpegBytes=${bytes.size}, quality=$quality, multiPage=$multiPage"
                    )
                    pages.add(bytes)
                }
                renderer.close()
                pages
            } finally {
                pfd.close()
            }
        } catch (e: Exception) {
            Log.w(TAG, "PDF render failed", e)
            emptyList()
        } finally {
            tempFile.delete()
        }
    }

    private fun sendIppRequest(ip: String, port: Int, path: String, requestBody: ByteArray): ByteArray {
        val url = URL("http://$ip:$port$path")
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.setRequestProperty("Content-Type", "application/ipp")
        conn.doOutput = true
        conn.connectTimeout = 30000
        conn.readTimeout = 30000
        conn.outputStream.use { it.write(requestBody) }
        val responseCode = conn.responseCode
        val responseBody = try {
            conn.inputStream?.readBytes() ?: byteArrayOf()
        } catch (_: Exception) {
            conn.errorStream?.readBytes() ?: byteArrayOf()
        }
        if (responseCode != 200) {
            val tail = if (responseBody.isNotEmpty()) " (response ${responseBody.size} bytes)" else ""
            throw Exception("HTTP $responseCode for $path$tail")
        }
        return responseBody
    }

    private fun checkIppResponse(responseBody: ByteArray) {
        if (responseBody.size < 8) {
            throw Exception("Invalid IPP response (too short: ${responseBody.size} bytes)")
        }
        val ippStatus = ((responseBody[2].toInt() and 0xFF) shl 8) or (responseBody[3].toInt() and 0xFF)
        if (ippStatus != 0x0000 && ippStatus != 0x0001) {
            val msg = when (ippStatus) {
                0x0400 -> "bad-request"
                0x040a -> "document-format-not-supported"
                0x0507 -> "printer busy"
                else -> "ipp-status-0x${Integer.toHexString(ippStatus)}"
            }
            throw Exception("Printer rejected: $msg")
        }
    }

    private data class JobInfo(val jobId: Int?, val jobUri: String?)

    private data class IppAttr(val name: String, val tag: Int, val value: ByteArray)

    /** Scans IPP response attributes with proper delimiter + additional-value handling. */
    private fun scanIppAttributes(responseBody: ByteArray): List<IppAttr> {
        if (responseBody.size < 9) return emptyList()
        val attrs = ArrayList<IppAttr>(64)
        var i = 8 // after version/status/request-id
        var lastName: String? = null

        while (i < responseBody.size) {
            val b = responseBody[i].toInt() and 0xFF
            i += 1
            if (b == 0x03) break // end-of-attributes-tag

            // Attribute group delimiter tags are 0x01,0x02,0x04..0x0F (RFC 8010)
            if (b == 0x01 || b == 0x02 || (b in 0x04..0x0F)) {
                continue
            }

            // Value-tag: attribute-with-one-value or additional-value
            val tag = b
            if (i + 2 > responseBody.size) break
            val nameLen = ((responseBody[i].toInt() and 0xFF) shl 8) or (responseBody[i + 1].toInt() and 0xFF)
            i += 2

            val name = if (nameLen == 0) {
                lastName ?: ""
            } else {
                if (i + nameLen > responseBody.size) break
                val n = String(responseBody, i, nameLen, StandardCharsets.UTF_8)
                i += nameLen
                lastName = n
                n
            }

            if (i + 2 > responseBody.size) break
            val valueLen = ((responseBody[i].toInt() and 0xFF) shl 8) or (responseBody[i + 1].toInt() and 0xFF)
            i += 2
            if (i + valueLen > responseBody.size) break
            val value = responseBody.copyOfRange(i, i + valueLen)
            i += valueLen

            if (name.isNotEmpty()) {
                attrs.add(IppAttr(name = name, tag = tag, value = value))
            }
        }
        return attrs
    }

    /** Try Create-Job; returns job-id/job-uri if present, else null. */
    private fun tryCreateJob(ip: String, port: Int, path: String, printerUri: String, requestId: Int): JobInfo? {
        return try {
            val createReq = buildIppCreateJobRequest(printerUri, requestId)
            val resp = sendIppRequestWithRetry(ip, port, path, createReq)
            checkIppResponse(resp)
            val info = parseJobInfoFromIppResponse(resp)
            if (info.jobId == null && info.jobUri == null) null else info
        } catch (e: Exception) {
            Log.i(TAG, "Create-Job failed: ${e.message}")
            null
        }
    }

    /** Parse job-id/job-uri from Create-Job/Print-Job response (best-effort). */
    private fun parseJobInfoFromIppResponse(responseBody: ByteArray): JobInfo {
        var jobId: Int? = null
        var jobUri: String? = null
        for (a in scanIppAttributes(responseBody)) {
            if (a.name == "job-id" && (a.tag == 0x21 || a.tag == 0x23) && a.value.size == 4) {
                jobId = ((a.value[0].toInt() and 0xFF) shl 24) or
                    ((a.value[1].toInt() and 0xFF) shl 16) or
                    ((a.value[2].toInt() and 0xFF) shl 8) or
                    (a.value[3].toInt() and 0xFF)
            } else if (a.name == "job-uri" && (a.tag == 0x45 || a.tag == 0x44) && a.value.isNotEmpty()) {
                jobUri = String(a.value, StandardCharsets.UTF_8)
            }
        }
        return JobInfo(jobId = jobId, jobUri = jobUri)
    }

    /** Parse job-state (enum/integer) from IPP Get-Job-Attributes response. */
    private fun parseJobStateFromIppResponse(responseBody: ByteArray): Int? {
        for (a in scanIppAttributes(responseBody)) {
            if (a.name == "job-state" && (a.tag == 0x23 || a.tag == 0x21) && a.value.size == 4) {
                return ((a.value[0].toInt() and 0xFF) shl 24) or
                    ((a.value[1].toInt() and 0xFF) shl 16) or
                    ((a.value[2].toInt() and 0xFF) shl 8) or
                    (a.value[3].toInt() and 0xFF)
            }
        }
        return null
    }

    private fun readPdfBytes(pdfPath: String): ByteArray {
        return when {
            pdfPath.startsWith("content://") -> {
                contentResolver.openInputStream(android.net.Uri.parse(pdfPath))?.use { it.readBytes() }
                    ?: throw Exception("Cannot read PDF from content URI")
            }
            else -> File(pdfPath).readBytes()
        }
    }

    private fun buildIppPrintJobRequest(
        printerUri: String,
        documentFormat: String,
        requestId: Int,
        jobName: String,
    ): ByteArray {
        val out = ByteArrayOutputStream()
        // IPP 1.1, Print-Job (0x0002)
        writeIppHeader(out, operationId = 0x0002, requestId = requestId)
        out.write(0x01) // operation-attributes-tag
        appendAttr(out, 0x47, "attributes-charset", "utf-8")
        appendAttr(out, 0x48, "attributes-natural-language", "en-us")
        appendAttr(out, 0x45, "printer-uri", printerUri)
        appendAttr(out, 0x42, "requesting-user-name", "anonymous")
        appendAttr(out, 0x42, "job-name", jobName)
        appendAttr(out, 0x49, "document-format", documentFormat)
        out.write(0x03) // end-of-attributes-tag
        return out.toByteArray()
    }

    private fun buildIppCreateJobRequest(printerUri: String, requestId: Int): ByteArray {
        val out = ByteArrayOutputStream()
        writeIppHeader(out, operationId = 0x0005, requestId = requestId) // Create-Job
        out.write(0x01) // operation-attributes-tag
        appendAttr(out, 0x47, "attributes-charset", "utf-8")
        appendAttr(out, 0x48, "attributes-natural-language", "en-us")
        appendAttr(out, 0x45, "printer-uri", printerUri)
        appendAttr(out, 0x42, "requesting-user-name", "anonymous")
        out.write(0x03) // end-of-attributes-tag
        return out.toByteArray()
    }

    private fun buildIppSendDocumentRequestByJobId(
        printerUri: String,
        jobId: Int,
        lastDocument: Boolean,
        documentFormat: String,
        requestId: Int,
    ): ByteArray {
        val out = ByteArrayOutputStream()
        writeIppHeader(out, operationId = 0x0006, requestId = requestId) // Send-Document
        out.write(0x01) // operation-attributes-tag
        appendAttr(out, 0x47, "attributes-charset", "utf-8")
        appendAttr(out, 0x48, "attributes-natural-language", "en-us")
        appendAttr(out, 0x45, "printer-uri", printerUri)
        appendAttrInt(out, "job-id", jobId)
        appendAttrBool(out, "last-document", lastDocument)
        appendAttr(out, 0x49, "document-format", documentFormat)
        out.write(0x03) // end-of-attributes-tag
        return out.toByteArray()
    }

    private fun buildIppSendDocumentRequestByJobUri(
        jobUri: String,
        lastDocument: Boolean,
        documentFormat: String,
        requestId: Int,
    ): ByteArray {
        val out = ByteArrayOutputStream()
        writeIppHeader(out, operationId = 0x0006, requestId = requestId) // Send-Document
        out.write(0x01) // operation-attributes-tag
        appendAttr(out, 0x47, "attributes-charset", "utf-8")
        appendAttr(out, 0x48, "attributes-natural-language", "en-us")
        appendAttr(out, 0x45, "job-uri", jobUri)
        appendAttrBool(out, "last-document", lastDocument)
        appendAttr(out, 0x49, "document-format", documentFormat)
        out.write(0x03)
        return out.toByteArray()
    }

    private fun appendAttr(out: ByteArrayOutputStream, valueTag: Int, name: String, value: String) {
        val nameBytes = name.toByteArray(StandardCharsets.UTF_8)
        val valueBytes = value.toByteArray(StandardCharsets.UTF_8)
        out.write(valueTag)
        out.write(shortToBigEndian(nameBytes.size))
        out.write(nameBytes)
        out.write(shortToBigEndian(valueBytes.size))
        out.write(valueBytes)
    }

    private fun appendAttrInt(out: ByteArrayOutputStream, name: String, value: Int) {
        val nameBytes = name.toByteArray(StandardCharsets.UTF_8)
        out.write(0x21) // integer
        out.write(shortToBigEndian(nameBytes.size))
        out.write(nameBytes)
        out.write(shortToBigEndian(4))
        out.write(byteArrayOf((value shr 24).toByte(), (value shr 16).toByte(), (value shr 8).toByte(), value.toByte()))
    }

    private fun appendAttrBool(out: ByteArrayOutputStream, name: String, value: Boolean) {
        val nameBytes = name.toByteArray(StandardCharsets.UTF_8)
        out.write(0x22) // boolean
        out.write(shortToBigEndian(nameBytes.size))
        out.write(nameBytes)
        out.write(shortToBigEndian(1))
        out.write(if (value) 1 else 0)
    }

    private fun shortToBigEndian(value: Int): ByteArray {
        return byteArrayOf((value shr 8).toByte(), value.toByte())
    }

    private fun writeIppHeader(out: ByteArrayOutputStream, operationId: Int, requestId: Int) {
        // Version 1.1
        out.write(0x01)
        out.write(0x01)
        // operation-id (2 bytes, big-endian)
        out.write((operationId shr 8) and 0xFF)
        out.write(operationId and 0xFF)
        // request-id (4 bytes, big-endian)
        out.write((requestId shr 24) and 0xFF)
        out.write((requestId shr 16) and 0xFF)
        out.write((requestId shr 8) and 0xFF)
        out.write(requestId and 0xFF)
    }

    private fun buildIppGetJobAttributesRequest(jobUri: String, requestId: Int): ByteArray {
        val out = ByteArrayOutputStream()
        writeIppHeader(out, operationId = 0x0009, requestId = requestId) // Get-Job-Attributes
        out.write(0x01)
        appendAttr(out, 0x47, "attributes-charset", "utf-8")
        appendAttr(out, 0x48, "attributes-natural-language", "en-us")
        appendAttr(out, 0x45, "job-uri", jobUri)
        appendAttr(out, 0x42, "requesting-user-name", "anonymous")
        out.write(0x03)
        return out.toByteArray()
    }
}

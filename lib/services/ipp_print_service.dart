import 'dart:convert';
import 'dart:io';
import '../models/printer_model.dart';

/// Sends PDF to a printer using IPP (Internet Printing Protocol).
/// The printer receives the job as "application/pdf" and should render it.
class IppPrintService {
  static const int defaultTimeoutSeconds = 30;
  static const int defaultIppPort = 631;

  // IPP status codes (RFC 8011): 0x00xx = success, 0x01xx = client error, 0x02xx = server error
  static const int _statusSuccessfulOk = 0x0000;
  static const int _statusSuccessfulOkIgnored = 0x0001;

  // Paths to try (order matters). Probing finds which one the printer supports.
  static const List<String> _paths = [
    '/',
    '/ipp/print',
    '/ipp/port1',
    '/ipp/printer',
    '/Print',
    '/print',
    '/ipp',
    '/printer',
    '/printers/ipp',
    '/hp/ipp/print',
  ];

  static void _appendAttr(List<int> out, int valueTag, String name, String value) {
    out.add(valueTag);
    final nameBytes = utf8.encode(name);
    final valueBytes = utf8.encode(value);
    out.add((nameBytes.length >> 8) & 0xff);
    out.add(nameBytes.length & 0xff);
    out.addAll(nameBytes);
    out.add((valueBytes.length >> 8) & 0xff);
    out.add(valueBytes.length & 0xff);
    out.addAll(valueBytes);
  }

  /// Get-Printer-Attributes (0x000B) - no document, used to probe if path works.
  static List<int> _buildGetPrinterAttributesRequest(String printerUri) {
    final out = <int>[];
    out.add(0x01);
    out.add(0x01);
    out.add(0x00);
    out.add(0x0B); // Get-Printer-Attributes
    out.add(0x00);
    out.add(0x00);
    out.add(0x00);
    out.add(0x01);
    out.add(0x01); // operation-attributes-tag
    _appendAttr(out, 0x47, 'attributes-charset', 'utf-8');
    _appendAttr(out, 0x48, 'attributes-natural-language', 'en-us');
    _appendAttr(out, 0x45, 'printer-uri', printerUri);
    out.add(0x03); // end-of-attributes-tag
    return out;
  }

  /// Builds Print-Job request (required attrs only; optional attrs can cause bad-request on strict printers).
  static List<int> _buildPrintJobRequest(String printerUri) {
    final out = <int>[];

    out.add(0x01);
    out.add(0x01);
    out.add(0x00);
    out.add(0x02); // Print-Job
    out.add(0x00);
    out.add(0x00);
    out.add(0x00);
    out.add(0x01); // request-id

    out.add(0x01); // operation-attributes-tag
    _appendAttr(out, 0x47, 'attributes-charset', 'utf-8');
    _appendAttr(out, 0x48, 'attributes-natural-language', 'en-us');
    _appendAttr(out, 0x45, 'printer-uri', printerUri);
    _appendAttr(out, 0x42, 'requesting-user-name', 'anonymous');
    _appendAttr(out, 0x49, 'document-format', 'application/pdf');

    out.add(0x03); // end-of-attributes-tag
    return out;
  }

  /// Returns IPP status code from response body (bytes 2-3, big-endian).
  static int _getIppStatusCode(List<int> body) {
    if (body.length < 4) return -1;
    return (body[2] << 8) | body[3];
  }

  static String _statusCodeMessage(int code) {
    if (code == _statusSuccessfulOk || code == _statusSuccessfulOkIgnored) return 'OK';
    switch (code) {
      case 0x0400:
        return 'bad-request';
      case 0x0401:
        return 'forbidden';
      case 0x0403:
        return 'not-possible';
      case 0x0404:
        return 'not-found (wrong path?)';
      case 0x0406:
        return 'not-found';
      case 0x040a:
        return 'document-format-not-supported (this printer does not accept PDF via IPP; use a printer that supports PDF)';
      case 0x0500:
        return 'internal-error';
      case 0x0502:
        return 'printer-busy';
      case 0x0503:
        return 'document-access-error';
      default:
        return 'ipp-status-0x${code.toRadixString(16)}';
    }
  }

  /// Probes path with Get-Printer-Attributes. Returns true if printer responds with IPP success.
  static Future<bool> _probePath(HttpClient client, String host, int port, String path) async {
    try {
      final printerUri = 'ipp://$host:$port$path';
      final body = _buildGetPrinterAttributesRequest(printerUri);
      final request = await client.postUrl(Uri.parse('http://$host:$port$path'));
      request.headers.set('Content-Type', 'application/ipp');
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close();
      final bodyBytes = (await response.toList()).expand((e) => e).toList();
      if (response.statusCode != 200) return false;
      final status = _getIppStatusCode(bodyBytes);
      return status == _statusSuccessfulOk || status == _statusSuccessfulOkIgnored;
    } catch (_) {
      return false;
    }
  }

  static Future<void> sendPdfToPrinter(PrinterModel printer, List<int> pdfBytes) async {
    final port = printer.port;
    final host = printer.ip;
    final customPath = printer.ippPath?.trim();
    List<String> pathsToTry = (customPath != null && customPath.isNotEmpty)
        ? [customPath.startsWith('/') ? customPath : '/$customPath']
        : List.from(_paths);

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: defaultTimeoutSeconds);

    Exception? lastError;
    try {
      // If no custom path, probe to find a working path first (any brand).
      if (customPath == null || customPath.isEmpty) {
        String? workingPath;
        for (final path in pathsToTry) {
          if (await _probePath(client, host, port, path)) {
            workingPath = path;
            break;
          }
        }
        if (workingPath != null) {
          pathsToTry = [workingPath];
        }
      }

      for (final path in pathsToTry) {
        try {
          final printerUri = 'ipp://$host:$port$path';
          final ippBody = _buildPrintJobRequest(printerUri);
          final requestBytes = <int>[...ippBody, ...pdfBytes];

          final request = await client.postUrl(Uri.parse('http://$host:$port$path'));
          request.headers.set('Content-Type', 'application/ipp');
          request.headers.set('User-Agent', 'DocPrint/1.0');
          request.contentLength = requestBytes.length;
          request.add(requestBytes);

          final response = await request.close();
          final body = await response.toList();
          final bodyBytes = body.expand((e) => e).toList();

          if (response.statusCode != 200) {
            lastError = Exception(
              'HTTP ${response.statusCode} for $path',
            );
            continue;
          }

          final ippStatus = _getIppStatusCode(bodyBytes);
          if (ippStatus < 0) {
            lastError = Exception('Invalid IPP response from printer');
            continue;
          }
          if (ippStatus != _statusSuccessfulOk && ippStatus != _statusSuccessfulOkIgnored) {
            lastError = Exception(
              'Printer rejected job: ${_statusCodeMessage(ippStatus)}',
            );
            continue;
          }

          return; // success
        } catch (e) {
          lastError = e is Exception ? e : Exception('$e');
        }
      }

      throw lastError ?? Exception('Print failed. Ensure printer supports IPP and is on the same network.');
    } finally {
      client.close();
    }
  }
}

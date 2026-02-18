import 'dart:io';
import 'package:flutter/services.dart';

/// Calls Android (Kotlin) to print PDF to printer by IP.
/// Use when [Platform.isAndroid]; otherwise use [NetworkPrintService] (Dart).
class PlatformPrintService {
  static const MethodChannel _channel = MethodChannel('doc_print/print');

  /// Returns true if the platform implements print (Android).
  static bool get isAvailable => Platform.isAndroid;

  /// Sends PDF at [pdfPath] to printer at [ip]:[port], optional [ippPath].
  /// Throws on failure.
  static Future<void> printPdfToPrinter({
    required String ip,
    required int port,
    String? ippPath,
    required String pdfPath,
  }) async {
    await _channel.invokeMethod<void>('printPdfToPrinter', <String, dynamic>{
      'ip': ip,
      'port': port,
      'ippPath': ippPath ?? '',
      'pdfPath': pdfPath,
    });
  }
}

import '../models/printer_model.dart';
import 'ipp_print_service.dart';

/// Sends PDF to a network printer by IP.
/// Uses IPP (Internet Printing Protocol) so the printer receives the job
/// as a PDF document and renders it, instead of printing raw bytes.
/// Default port 631 is used for IPP; ensure your printer supports IPP.
class NetworkPrintService {
  /// Sends [pdfBytes] to [printer] via IPP. Printer must support IPP (typically port 631).
  static Future<void> sendPdfToPrinter(PrinterModel printer, List<int> pdfBytes) async {
    await IppPrintService.sendPdfToPrinter(printer, pdfBytes);
  }
}

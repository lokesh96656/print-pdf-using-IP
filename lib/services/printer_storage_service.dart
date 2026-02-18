import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/printer_model.dart';

const String _keyPrinters = 'ip_printers';

class PrinterStorageService {
  static Future<List<PrinterModel>> getPrinters() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyPrinters);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => PrinterModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> savePrinters(List<PrinterModel> printers) async {
    final prefs = await SharedPreferences.getInstance();
    final list = printers.map((e) => e.toJson()).toList();
    await prefs.setString(_keyPrinters, jsonEncode(list));
  }

  static Future<void> addPrinter(PrinterModel printer) async {
    final list = await getPrinters();
    if (list.any((e) => e.id == printer.id)) return;
    list.add(printer);
    await savePrinters(list);
  }

  static Future<void> removePrinter(String id) async {
    final list = await getPrinters();
    list.removeWhere((e) => e.id == id);
    await savePrinters(list);
  }

  static Future<void> updatePrinter(PrinterModel printer) async {
    final list = await getPrinters();
    final i = list.indexWhere((e) => e.id == printer.id);
    if (i >= 0) {
      list[i] = printer;
      await savePrinters(list);
    }
  }
}

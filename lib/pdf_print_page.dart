import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'models/printer_model.dart';
import 'services/printer_storage_service.dart';
import 'services/network_print_service.dart';
import 'services/platform_print_service.dart';
import 'manage_printers_page.dart';

// Flow: (1) Printer selection is IP-based only.
//       (2) On Android, PDF printing always uses Kotlin with the selected printer's IP (and port/ippPath).

class PdfPrintPage extends StatefulWidget {
  const PdfPrintPage({super.key});

  @override
  State<PdfPrintPage> createState() => _PdfPrintPageState();
}

class _PdfPrintPageState extends State<PdfPrintPage> {
  File? _selectedPdf;
  /// Path from picker (file path or content URI). Used for Kotlin on Android.
  String? _selectedPdfPath;
  String? _fileName;
  /// PDF bytes when picker gave bytes but no path (e.g. some Android pickers).
  List<int>? _selectedPdfBytes;
  bool _isLoading = false;
  String? _errorMessage;
  List<PrinterModel> _printers = [];
  PrinterModel? _selectedPrinter;

  @override
  void initState() {
    super.initState();
    _loadPrinters();
  }

  Future<void> _loadPrinters() async {
    final list = await PrinterStorageService.getPrinters();
    if (mounted) {
      setState(() {
        _printers = list;
        if (_selectedPrinter != null) {
          try {
            _selectedPrinter = list.firstWhere((p) => p.id == _selectedPrinter!.id);
          } catch (_) {
            _selectedPrinter = null;
          }
        }
      });
    }
  }

  Future<void> _pickPdf() async {
    try {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.single;
        final path = file.path;
        final bytes = file.bytes;
        setState(() {
          _fileName = file.name;
          if (path != null && path.isNotEmpty) {
            _selectedPdf = File(path);
            _selectedPdfPath = path;
            _selectedPdfBytes = null;
          } else if (bytes != null && bytes.isNotEmpty) {
            _selectedPdfBytes = bytes;
            _selectedPdfPath = null;
            _selectedPdf = null;
          } else {
            _selectedPdf = null;
            _selectedPdfPath = null;
            _selectedPdfBytes = null;
          }
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error picking file: $e';
      });
    }
  }

  Future<void> _printPdf() async {
    final hasFile = _selectedPdf != null || (_selectedPdfBytes != null && _selectedPdfBytes!.isNotEmpty);
    if (!hasFile) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a PDF file first'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_selectedPrinter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a printer (or add one in Manage Printers)'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      // (1) Printer selection is IP-based. (2) On Android, printing always uses Kotlin with selected printer IP.
      if (Platform.isAndroid) {
        String pdfPath;
        if (_selectedPdfPath != null && _selectedPdfPath!.isNotEmpty) {
          pdfPath = _selectedPdfPath!;
        } else if (_selectedPdfBytes != null && _selectedPdfBytes!.isNotEmpty) {
          final dir = Directory.systemTemp;
          final f = File('${dir.path}/doc_print_${DateTime.now().millisecondsSinceEpoch}.pdf');
          await f.writeAsBytes(_selectedPdfBytes!);
          pdfPath = f.path;
        } else {
          pdfPath = _selectedPdf!.path;
        }
        try {
          await PlatformPrintService.printPdfToPrinter(
            ip: _selectedPrinter!.ip,
            port: _selectedPrinter!.port,
            ippPath: _selectedPrinter!.ippPath,
            pdfPath: pdfPath,
          );
        } on MissingPluginException {
          throw Exception(
            'Android native print code not loaded (MissingPluginException). '
            'Stop the app completely and re-run (hot reload/restart is not enough after Kotlin changes).',
          );
        }
      } else {
        final pdfBytes = _selectedPdfBytes ??
            (await _selectedPdf!.readAsBytes());
        await NetworkPrintService.sendPdfToPrinter(_selectedPrinter!, pdfBytes);
      }

      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sent to ${_selectedPrinter!.displayLabel}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } on PlatformException catch (e) {
      setState(() {
        _isLoading = false;
        final msg = e.message ?? e.code;
        if (msg.contains('document-format-not-supported') ||
            msg.contains('does not accept PDF via IPP')) {
          _errorMessage =
              'This printer doesn\'t support PDF over IPP. '
              'Use a printer that supports IPP PDF, or try another IPP path/port in Manage Printers.';
        } else {
          _errorMessage = 'Error printing: $msg';
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_errorMessage ?? 'Error: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error printing: $e';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  bool get _hasFile =>
      _selectedPdf != null ||
      (_selectedPdfBytes != null && _selectedPdfBytes!.isNotEmpty);

  void _clearSelection() {
    setState(() {
      _selectedPdf = null;
      _selectedPdfPath = null;
      _selectedPdfBytes = null;
      _fileName = null;
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF Printer'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ManagePrintersPage()),
              );
              await _loadPrinters();
            },
            tooltip: 'Manage printers (by IP)',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Section
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      Icon(
                        Icons.picture_as_pdf,
                        size: 64,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Select and Print PDF',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Print PDF to a printer by IP (IPP). Printer must support PDF over IPP on the same network.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.grey[600],
                            ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // File Selection Section
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Selected File',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 12),
                      if (!_hasFile)
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[300]!),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.insert_drive_file, color: Colors.grey[600]),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'No file selected',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue[200]!),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.picture_as_pdf, color: Colors.blue[700]),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _fileName ?? 'PDF File',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'File selected',
                                      style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: _clearSelection,
                                tooltip: 'Clear selection',
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Error Message
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red[300]!),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red[700]),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: Colors.red[700]),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_errorMessage != null) const SizedBox(height: 16),

              // Printer selection (by IP)
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Printer (by IP)',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          if (_printers.isEmpty)
                            Text(
                              ' — Add in Manage Printers',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_printers.isEmpty)
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const ManagePrintersPage()),
                            );
                            await _loadPrinters();
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('Add printer by IP'),
                        )
                      else
                        DropdownButtonFormField<PrinterModel>(
                          value: _printers.any((p) => p.id == _selectedPrinter?.id)
                              ? _printers.firstWhere((p) => p.id == _selectedPrinter!.id)
                              : null,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                          hint: const Text('Select printer'),
                          items: _printers
                              .map((p) => DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p.displayLabel,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ))
                              .toList(),
                          onChanged: (p) => setState(() => _selectedPrinter = p),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Action Buttons
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _pickPdf,
                        icon: _isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.folder_open),
                        label: Text(_isLoading ? 'Loading...' : 'Select PDF File'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.white,
                          elevation: 2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: (_isLoading || !_hasFile)
                            ? null
                            : _printPdf,
                        icon: const Icon(Icons.print),
                        label: const Text('Print PDF'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green[600],
                          foregroundColor: Colors.white,
                          elevation: 2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

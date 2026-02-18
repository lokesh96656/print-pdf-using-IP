import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/printer_model.dart';
import '../services/printer_storage_service.dart';
import '../services/printer_discovery_service.dart';

class ManagePrintersPage extends StatefulWidget {
  const ManagePrintersPage({super.key});

  @override
  State<ManagePrintersPage> createState() => _ManagePrintersPageState();
}

class _ManagePrintersPageState extends State<ManagePrintersPage> {
  List<PrinterModel> _printers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await PrinterStorageService.getPrinters();
    setState(() {
      _printers = list;
      _loading = false;
    });
  }

  Future<void> _addOrEdit({PrinterModel? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final ipController = TextEditingController(text: existing?.ip ?? '');
    final portController = TextEditingController(
      text: existing != null ? '${existing.port}' : '631',
    );
    final ippPathController = TextEditingController(text: existing?.ippPath ?? '');
    final isEdit = existing != null;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isEdit ? 'Edit printer' : 'Add printer by IP'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name (optional)',
                  hintText: 'e.g. Office HP',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ipController,
                decoration: const InputDecoration(
                  labelText: 'IP address',
                  hintText: '192.168.1.100',
                ),
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: portController,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  hintText: '631, 280, or 80 (HP: try 280 or 80)',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ippPathController,
                decoration: const InputDecoration(
                  labelText: 'IPP path (optional)',
                  hintText: 'e.g. /ipp/print — leave blank to auto-try',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final ip = ipController.text.trim();
              final port = int.tryParse(portController.text.trim()) ?? 631;
              if (ip.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enter IP address')),
                );
                return;
              }
              final name = nameController.text.trim();
              final ippPath = ippPathController.text.trim();
              final id = existing?.id ?? '${ip}_$port';
              final p = PrinterModel(
                id: id,
                ip: ip,
                name: name.isEmpty ? null : name,
                port: port,
                ippPath: ippPath.isEmpty ? null : ippPath,
              );
              if (isEdit) {
                await PrinterStorageService.updatePrinter(p);
              } else {
                await PrinterStorageService.addPrinter(p);
              }
              if (mounted) Navigator.of(context).pop();
              await _load();
            },
            child: Text(isEdit ? 'Save' : 'Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _discoverPrinters() async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 24),
            Expanded(child: Text('Searching for printers on network…')),
          ],
        ),
      ),
    );
    List<PrinterModel> found;
    try {
      found = await PrinterDiscoveryService.discoverPrinters();
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Discovery failed: $e'), backgroundColor: Colors.red),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    if (found.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No IPP printers found. Add one manually by IP.')),
      );
      return;
    }
    final addedIds = <String>{..._printers.map((s) => s.id)};
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Printers found'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${found.length} printer(s) found. Tap Add to save.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                ...found.map((p) {
                  final alreadyAdded = addedIds.contains(p.id);
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.print),
                      title: Text(p.name ?? 'Printer'),
                      subtitle: Text(
                        '${p.ip}:${p.port}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      trailing: alreadyAdded
                          ? const Text('Added', style: TextStyle(color: Colors.grey))
                          : FilledButton(
                              onPressed: () async {
                                await PrinterStorageService.addPrinter(p);
                                addedIds.add(p.id);
                                if (mounted) {
                                  setDialogState(() {});
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Added ${p.displayLabel}')),
                                  );
                                }
                              },
                              child: const Text('Add'),
                            ),
                    ),
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    await _load();
  }

  Future<void> _delete(PrinterModel p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove printer?'),
        content: Text('Remove ${p.displayLabel}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await PrinterStorageService.removePrinter(p.id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Printers by IP'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _discoverPrinters(),
            tooltip: 'Discover printers on network',
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _addOrEdit(),
            tooltip: 'Add printer by IP',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _printers.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.print_disabled,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No printers added',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add a printer by IP to print PDFs directly',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: () => _discoverPrinters(),
                        icon: const Icon(Icons.search),
                        label: const Text('Discover printers'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => _addOrEdit(),
                        icon: const Icon(Icons.add),
                        label: const Text('Add by IP manually'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _printers.length,
                  itemBuilder: (context, i) {
                    final p = _printers[i];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.print),
                        title: Text(p.name ?? 'Printer'),
                        subtitle: Text(
                          '${p.ip}:${p.port}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: () => _addOrEdit(existing: p),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(p),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

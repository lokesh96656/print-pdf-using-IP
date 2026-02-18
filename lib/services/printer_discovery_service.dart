import 'package:multicast_dns/multicast_dns.dart';
import '../models/printer_model.dart';

/// Discovers IPP printers on the local network using mDNS (Bonjour).
/// Printers that advertise _ipp._tcp.local are found with their IP and port.
class PrinterDiscoveryService {
  static const String _ippServiceType = '_ipp._tcp.local';
  static const Duration _lookupTimeout = Duration(seconds: 8);

  /// Discovers IPP printers. Returns a list of [PrinterModel] with IP, port, and optional name.
  static Future<List<PrinterModel>> discoverPrinters() async {
    final results = <PrinterModel>[];
    final seen = <String>{};
    final client = MDnsClient();

    try {
      await client.start();

      await for (final PtrResourceRecord ptr
          in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(_ippServiceType),
        timeout: _lookupTimeout,
      )) {
        await for (final SrvResourceRecord srv
            in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
          timeout: const Duration(seconds: 2),
        )) {
          String? ip;
          await for (final IPAddressResourceRecord ipRec
              in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
            timeout: const Duration(seconds: 2),
          )) {
            ip = ipRec.address.address;
            break;
          }
          if (ip == null) continue;
          final key = '$ip:${srv.port}';
          if (seen.contains(key)) continue;
          seen.add(key);
          final name = _friendlyName(srv.name);
          final ippPath = await _getResourcePath(client, ptr.domainName);
          results.add(PrinterModel(
            id: key,
            ip: ip,
            name: name,
            port: srv.port,
            ippPath: ippPath,
          ));
        }
      }
    } finally {
      client.stop();
    }

    return results;
  }

  static String _friendlyName(String fqdn) {
    if (fqdn.isEmpty) return 'Printer';
    final withoutLocal = fqdn.replaceAll(RegExp(r'\.local\.?$'), '');
    final parts = withoutLocal.split('.');
    return parts.isNotEmpty ? parts.first : withoutLocal;
  }

  /// Gets IPP resource path from Bonjour TXT record "rp=" (resource path).
  static Future<String?> _getResourcePath(MDnsClient client, String domainName) async {
    try {
      await for (final TxtResourceRecord txt in client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(domainName),
        timeout: const Duration(seconds: 1),
      )) {
        final t = txt.text;
        final rpMatch = RegExp(r'rp=([^\x00-\x1f\x7f-\xff]+)').firstMatch(t);
        if (rpMatch == null) continue;
        String path = rpMatch.group(1)!.trim();
        if (path.isEmpty) continue;
        return path.startsWith('/') ? path : '/$path';
      }
    } catch (_) {}
    return null;
  }
}

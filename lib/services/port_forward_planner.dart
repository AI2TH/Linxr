import '../models/marketplace_item.dart';

enum PortPlanStatus {
  /// Not forwarded yet; can be added.
  add,

  /// Linxr already forwards this host port to the same guest port.
  alreadyForwarded,

  /// The host port is already forwarded to a different guest port, or used
  /// twice by this recipe.
  conflict,

  /// SSH (2222) and the VM API (7081) are never available to recipes.
  reserved,

  /// UDP: QEMU user networking (SLIRP hostfwd) is set up for TCP only.
  udpUnsupported,
}

class PortPlan {
  const PortPlan({
    required this.host,
    required this.guest,
    required this.status,
    this.conflictWith,
    this.mayNeedUdp = false,
  });

  final int host;
  final int guest;
  final PortPlanStatus status;

  /// Description of the forward this one collides with.
  final String? conflictWith;

  /// A well-known port for a service that usually also (or only) uses UDP,
  /// e.g. SIP on 5060: the TCP forward alone may not be enough.
  final bool mayNeedUdp;
}

/// Works out which of a recipe's declared ports can be added as host -> guest
/// forwards (VmManager custom port forwards), with a collision check.
class PortForwardPlanner {
  PortForwardPlanner._();

  static const reservedHostPorts = {2222, 7081};

  /// Ports of services that normally use UDP (SIP, DNS, NTP, SNMP, IPsec,
  /// OpenVPN, RADIUS, mDNS, Tailscale, WireGuard).
  static const udpServicePorts = {53, 123, 161, 500, 1194, 1812, 4500, 5060, 5353, 41641, 51820};

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v');

  /// Guest port the service listens on inside the VM.
  /// - script recipes: `container` (the service runs in the VM itself);
  /// - docker, host network: `container` (no publishing, the container
  ///   listens on the VM's own port);
  /// - docker, other networks: `host` (published with -p host:container).
  static int? guestPortFor(MarketplaceItem item, Map<String, dynamic> port) {
    final host = _int(port['host']);
    final container = _int(port['container']) ?? host;
    if (item.isScript) return container;
    return item.network == 'host' ? container : host;
  }

  static bool _isUdp(Map<String, dynamic> port) {
    final proto = (port['protocol'] ?? port['proto'] ?? '').toString().toLowerCase();
    return proto == 'udp';
  }

  static List<PortPlan> plan(
    MarketplaceItem item,
    List<Map<String, dynamic>> existingForwards,
  ) {
    final existing = <int, Map<String, dynamic>>{};
    for (final f in existingForwards) {
      final h = _int(f['host']);
      if (h != null) existing[h] = f;
    }
    final seen = <int>{};
    final plans = <PortPlan>[];
    for (final port in item.ports) {
      final host = _int(port['host']);
      final guest = guestPortFor(item, port);
      if (host == null || guest == null || host <= 0 || host > 65535 || guest <= 0 || guest > 65535) {
        continue;
      }
      final mayNeedUdp = udpServicePorts.contains(guest) || udpServicePorts.contains(host);
      PortPlanStatus status;
      String? conflictWith;
      if (_isUdp(port)) {
        status = PortPlanStatus.udpUnsupported;
      } else if (reservedHostPorts.contains(host)) {
        status = PortPlanStatus.reserved;
      } else if (seen.contains(host)) {
        status = PortPlanStatus.conflict;
        conflictWith = 'another port of this recipe';
      } else if (existing.containsKey(host)) {
        final f = existing[host]!;
        if (_int(f['guest']) == guest) {
          status = PortPlanStatus.alreadyForwarded;
        } else {
          status = PortPlanStatus.conflict;
          conflictWith = '${f['desc'] ?? 'forward'} (host $host -> guest ${f['guest']})';
        }
      } else {
        status = PortPlanStatus.add;
      }
      seen.add(host);
      plans.add(PortPlan(
        host: host,
        guest: guest,
        status: status,
        conflictWith: conflictWith,
        mayNeedUdp: mayNeedUdp,
      ));
    }
    return plans;
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:linxr/models/marketplace_item.dart';
import 'package:linxr/services/port_forward_planner.dart';

MarketplaceItem _recipe(List<Map<String, dynamic>> ports,
        {RecipeType type = RecipeType.script, String network = 'host'}) =>
    MarketplaceItem(
      id: 'r',
      name: 'Recipe',
      category: 'Utilities',
      type: type,
      description: '',
      ports: ports,
      network: network,
    );

void main() {
  final defaults = [
    {'host': 2222, 'guest': 22, 'desc': 'SSH'},
    {'host': 8088, 'guest': 80, 'desc': 'HTTP (80 -> 8088)'},
    {'host': 8080, 'guest': 8080, 'desc': 'HTTP / web apps'},
  ];

  test('new ports are added, identical forwards are skipped', () {
    final plans = PortForwardPlanner.plan(
      _recipe([
        {'host': 8088, 'container': 80},
        {'host': 9090, 'container': 9090},
      ]),
      defaults,
    );
    expect(plans.map((p) => p.status), [PortPlanStatus.alreadyForwarded, PortPlanStatus.add]);
  });

  test('a host port forwarded elsewhere is a conflict', () {
    final plans = PortForwardPlanner.plan(_recipe([{'host': 8088, 'container': 8088}]), defaults);
    expect(plans.single.status, PortPlanStatus.conflict);
    expect(plans.single.conflictWith, contains('HTTP (80 -> 8088)'));
  });

  test('reserved, duplicate and UDP ports are not added', () {
    final plans = PortForwardPlanner.plan(
      _recipe([
        {'host': 2222, 'container': 2222},
        {'host': 9100, 'container': 9100},
        {'host': 9100, 'container': 9101},
        {'host': 5060, 'container': 5060, 'protocol': 'udp'},
      ]),
      defaults,
    );
    expect(plans.map((p) => p.status), [
      PortPlanStatus.reserved,
      PortPlanStatus.add,
      PortPlanStatus.conflict,
      PortPlanStatus.udpUnsupported,
    ]);
  });

  test('SIP over TCP is added but flagged as possibly needing UDP', () {
    final plan = PortForwardPlanner.plan(_recipe([{'host': 5060, 'container': 5060}]), defaults).single;
    expect(plan.status, PortPlanStatus.add);
    expect(plan.mayNeedUdp, isTrue);
  });

  test('guest port depends on recipe type and network', () {
    const port = {'host': 8090, 'container': 80};
    expect(PortForwardPlanner.guestPortFor(_recipe([]), port), 80);
    expect(
        PortForwardPlanner.guestPortFor(
            _recipe([], type: RecipeType.docker, network: 'host'), port),
        80);
    expect(
        PortForwardPlanner.guestPortFor(
            _recipe([], type: RecipeType.docker, network: 'bridge'), port),
        8090);
  });
}

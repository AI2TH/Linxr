import 'package:flutter_test/flutter_test.dart';
import 'package:linxr/models/marketplace_item.dart';
import 'package:linxr/services/marketplace_service.dart';

void main() {
  test('exported recipe JSON imports back as an equivalent custom recipe', () {
    const original = MarketplaceItem(
      id: 'custom_1',
      name: 'My Stack',
      category: 'Community',
      type: RecipeType.docker,
      description: 'Test recipe',
      image: 'nginx:alpine',
      command: ['nginx', '-g', 'daemon off;'],
      ports: [
        {'host': 8090, 'container': 80},
      ],
      env: [
        {'key': 'MODE', 'value': 'test'},
      ],
      network: 'bridge',
      notes: 'notes',
      isCustom: true,
    );

    final json = MarketplaceService.exportRecipeToJson(original);
    final imported = MarketplaceService.importRecipeFromJson(json);

    expect(imported.isCustom, isTrue);
    expect(imported.id, startsWith('custom_'));
    expect(imported.name, original.name);
    expect(imported.category, original.category);
    expect(imported.type, original.type);
    expect(imported.description, original.description);
    expect(imported.image, original.image);
    expect(imported.command, original.command);
    expect(imported.ports, original.ports);
    expect(imported.env, original.env);
    expect(imported.network, original.network);
    expect(imported.notes, original.notes);
  });

  test('no built-in recipe collides with a host port reserved by Linxr', () {
    // SSH and the VM API are never available to recipes.
    const alwaysReserved = {2222, 7081};
    // Default forwards a recipe may only use for the same service, i.e. with
    // the same mapping Linxr already sets up (VmManager.portForwards).
    const defaultForwards = {5900: 5900, 6080: 6080, 8088: 80, 11434: 11434};
    for (final item in MarketplaceService.builtInItems) {
      for (final p in item.ports) {
        final host = (p['host'] as num).toInt();
        final container = (p['container'] as num).toInt();
        expect(alwaysReserved.contains(host), isFalse,
            reason: '${item.id} maps reserved host port $host');
        if (defaultForwards.containsKey(host)) {
          expect(container, defaultForwards[host],
              reason: '${item.id} maps host $host to $container, but Linxr '
                  'forwards host $host to guest ${defaultForwards[host]}');
        }
      }
    }
  });
}

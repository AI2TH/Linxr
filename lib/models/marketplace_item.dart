import 'package:flutter/material.dart';

enum RecipeType {
  docker,
  script,
}

class MarketplaceItem {
  final String id;
  final String name;
  final String category;
  final RecipeType type;
  final String description;
  final String author;
  final String version;
  final int iconCodePoint;
  final String? iconFontFamily;
  final String? image;
  final List<String> command;
  final List<Map<String, dynamic>> ports;
  final List<Map<String, String>> env;
  final String network;
  final String? script;
  final String? notes;
  final bool isCustom;

  const MarketplaceItem({
    required this.id,
    required this.name,
    required this.category,
    required this.type,
    required this.description,
    this.author = 'Linxr Official',
    this.version = '1.0.0',
    this.iconCodePoint = 0xe6a8, // Icons.widgets
    this.iconFontFamily,
    this.image,
    this.command = const [],
    this.ports = const [],
    this.env = const [],
    this.network = 'host',
    this.script,
    this.notes,
    this.isCustom = false,
  });

  IconData get iconData => IconData(
        iconCodePoint,
        fontFamily: iconFontFamily ?? 'MaterialIcons',
      );

  int? get primaryPort => ports.isNotEmpty ? ((ports.first['host'] as num?)?.toInt()) : null;
  bool get hasWebUi => primaryPort != null;
  String? get webUrl => hasWebUi ? 'http://localhost:$primaryPort' : null;
  bool get isDocker => type == RecipeType.docker;
  bool get isScript => type == RecipeType.script;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'category': category,
      'type': type == RecipeType.docker ? 'docker' : 'script',
      'description': description,
      'author': author,
      'version': version,
      'iconCodePoint': iconCodePoint,
      'iconFontFamily': iconFontFamily,
      'image': image,
      'command': command,
      'ports': ports,
      'env': env,
      'network': network,
      'script': script,
      'notes': notes,
      'isCustom': isCustom,
    };
  }

  factory MarketplaceItem.fromJson(Map<String, dynamic> json) {
    return MarketplaceItem(
      id: json['id'] as String? ?? 'item_${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? 'Untitled Recipe',
      category: json['category'] as String? ?? 'Community',
      type: (json['type'] as String?) == 'script'
          ? RecipeType.script
          : RecipeType.docker,
      description: json['description'] as String? ?? '',
      author: json['author'] as String? ?? 'Community',
      version: json['version'] as String? ?? '1.0.0',
      iconCodePoint: (json['iconCodePoint'] as num?)?.toInt() ?? 0xe6a8,
      iconFontFamily: json['iconFontFamily'] as String?,
      image: json['image'] as String?,
      command: (json['command'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      ports: (json['ports'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          const [],
      env: (json['env'] as List<dynamic>?)
              ?.map((e) => Map<String, String>.from(
                  (e as Map).map((k, v) => MapEntry(k.toString(), v.toString()))))
              .toList() ??
          const [],
      network: json['network'] as String? ?? 'host',
      script: json['script'] as String?,
      notes: json['notes'] as String?,
      isCustom: (json['isCustom'] as bool?) ?? true,
    );
  }

  MarketplaceItem copyWith({
    String? id,
    String? name,
    String? category,
    RecipeType? type,
    String? description,
    String? author,
    String? version,
    int? iconCodePoint,
    String? iconFontFamily,
    String? image,
    List<String>? command,
    List<Map<String, dynamic>>? ports,
    List<Map<String, String>>? env,
    String? network,
    String? script,
    String? notes,
    bool? isCustom,
  }) {
    return MarketplaceItem(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      type: type ?? this.type,
      description: description ?? this.description,
      author: author ?? this.author,
      version: version ?? this.version,
      iconCodePoint: iconCodePoint ?? this.iconCodePoint,
      iconFontFamily: iconFontFamily ?? this.iconFontFamily,
      image: image ?? this.image,
      command: command ?? this.command,
      ports: ports ?? this.ports,
      env: env ?? this.env,
      network: network ?? this.network,
      script: script ?? this.script,
      notes: notes ?? this.notes,
      isCustom: isCustom ?? this.isCustom,
    );
  }
}

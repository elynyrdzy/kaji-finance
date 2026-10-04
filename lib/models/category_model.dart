import 'package:flutter/material.dart';

import '../utils/app_icons.dart';

class CategoryModel {
  final String id;
  final String name;
  final IconData icon;

  const CategoryModel({
    required this.id,
    required this.name,
    required this.icon,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'icon': icon.codePoint,
      };
  factory CategoryModel.fromJson(Map<String, dynamic> j) => CategoryModel(
        id: j['id'] as String,
        name: j['name'] as String,
        icon: AppIcons.fromCodePoint(j['icon'] as int),
      );
}

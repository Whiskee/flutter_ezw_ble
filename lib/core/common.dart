import 'package:flutter/material.dart';

/// 简易路由跳转
void evnPush<T extends Widget>(BuildContext context, T page, String pageName) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => page,
        settings: RouteSettings(name: pageName),
      ),
    );

void evenPod(BuildContext context) => Navigator.of(context).pop();

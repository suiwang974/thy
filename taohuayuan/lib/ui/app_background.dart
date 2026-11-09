import 'package:flutter/material.dart';

/// 第 61 条（2026-11-09 用户指定）：App 背景图——DS娘比基尼吃冰棍，
/// `assets/app-background.jpg`（原图 960×1403，md5 与用户发来的文件一致）。
/// 四个栏（推荐 / 短视频 / 浏览器 / 我的）底层都铺这张图。
/// 图只有 960×1403，全屏会有点糊：上面压一层 0.62 的黑色遮罩，
/// 既压暗提糊感、也保证白色文字在亮图上可读；卡片本身有自己的深色底，
/// 文字样式不动。不要擅自换图。
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  static const String asset = 'assets/app-background.jpg';

  /// 遮罩不透明度：0.62——白字可读、图还看得见。
  static const double dimOpacity = 0.62;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(asset, fit: BoxFit.cover),
        Container(color: Colors.black.withValues(alpha: dimOpacity)),
        child,
      ],
    );
  }
}

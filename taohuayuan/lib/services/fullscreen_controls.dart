import 'dart:async';

import 'package:flutter/foundation.dart';

/// 全屏控制条自动隐藏（第 43+44 条）：
///
/// - 全屏要有完整控制条（进度条可拖、倍速、分辨率、退出全屏键）；
/// - 播的时候 3 秒无操作自动藏起来，点一下画面再出现；
/// - 暂停时不藏（暂停了还藏控制条，用户找不到继续键）；
/// - 点视频区只做暂停/继续 + 唤出控制条，绝不触发放大/全屏切换。
///
/// 详情页全屏和短视频全屏共用这一套。Timer 工厂可注入，单元测试不用等真 3 秒；
/// 计时回调带代际号，退出全屏/重新 poke 后旧回调触发也不再藏条。
class FullscreenControls {
  FullscreenControls({
    this.hideAfter = const Duration(seconds: 3),
    Timer Function(Duration, void Function())? timerFactory,
    this.onChanged,
  }) : _timerFactory = timerFactory ?? ((d, cb) => Timer(d, cb));

  final Duration hideAfter;
  final Timer Function(Duration, void Function()) _timerFactory;
  final VoidCallback? onChanged;

  bool visible = true;
  Timer? _timer;
  int _gen = 0;

  /// 用户有操作（点画面、按按钮、切档）：控制条重新出现；播的时候重新计时 3 秒。
  void poke({required bool isPlaying}) {
    visible = true;
    _timer?.cancel();
    _timer = null;
    if (!isPlaying) return;
    final g = ++_gen;
    _timer = _timerFactory(hideAfter, () {
      if (g != _gen) return; // 已被新 poke/退出全屏作废的旧计时。
      visible = false;
      onChanged?.call();
    });
  }

  /// 退出全屏：取消计时、控制条恢复常显。
  void reset() {
    _gen++;
    _timer?.cancel();
    _timer = null;
    visible = true;
  }

  void dispose() {
    _gen++;
    _timer?.cancel();
    _timer = null;
  }
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/services/fullscreen_controls.dart';

class _FakeTimer implements Timer {
  _FakeTimer({this.onCancel});
  final void Function()? onCancel;
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
  @override
  void cancel() => onCancel?.call();
}

void main() {
  test('第 43+44 条：点画面控制条出现，播的时候 3 秒后自动藏', () {
    void Function()? fired;
    var created = false;
    final c = FullscreenControls(
      hideAfter: const Duration(seconds: 3),
      timerFactory: (d, cb) {
        expect(d, const Duration(seconds: 3));
        created = true;
        fired = cb;
        return _FakeTimer();
      },
    );
    c.poke(isPlaying: true);
    expect(c.visible, isTrue);
    expect(created, isTrue);
    expect(fired, isNotNull);
    fired!();
    expect(c.visible, isFalse);
  });

  test('第 44 条：暂停时不启动隐藏计时（控制条留着）', () {
    var created = false;
    final c = FullscreenControls(
      timerFactory: (d, cb) {
        created = true;
        return _FakeTimer();
      },
    );
    c.poke(isPlaying: false);
    expect(c.visible, isTrue);
    expect(created, isFalse);
  });

  test('第 44 条：退出全屏取消计时、控制条恢复常显，旧计时触发也不再藏条', () {
    void Function()? fired;
    var cancelled = false;
    var changed = 0;
    final c = FullscreenControls(
      timerFactory: (d, cb) {
        fired = cb;
        return _FakeTimer(onCancel: () => cancelled = true);
      },
      onChanged: () => changed++,
    );
    c.poke(isPlaying: true);
    c.reset();
    expect(c.visible, isTrue);
    expect(cancelled, isTrue);
    fired!(); // 已作废的旧计时触发也不该藏条、不该回调。
    expect(c.visible, isTrue);
    expect(changed, 0);
  });

  test('第 44 条：重新 poke 会取消旧计时、再等 3 秒', () {
    var cancels = 0;
    final c = FullscreenControls(
      timerFactory: (d, cb) => _FakeTimer(onCancel: () => cancels++),
    );
    c.poke(isPlaying: true);
    c.poke(isPlaying: true);
    expect(cancels, 1);
    expect(c.visible, isTrue);
  });
}

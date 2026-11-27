import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 把鼠标滚轮的竖向增量交给一条只能横滑的行。
///
/// 触屏和 TV 不产生滚轮信号，这一层对它们完全透明；桌面/Web 上若不接住，
/// `SingleChildScrollView(direction: horizontal)` 吃不下 dy，手势会漏给外层
/// 纵向列表——观众想看行尾的词，结果整页滚走了。
///
/// 注册到 [GestureBinding] 的 resolver 而不是只改 controller：同一份信号由最深
/// 的命中目标先认领，外层的纵向滚动便不会再花一次。到边界时不认领，把滚轮
/// 还给页面——「行已经滑完了」不是「这一页也不许滚」。
class HorizontalWheel extends StatelessWidget {
  final ScrollController controller;
  final Widget child;

  const HorizontalWheel({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent) return;
      if (!controller.hasClients) return;
      final position = controller.position;
      if (position.maxScrollExtent <= position.minScrollExtent) return;
      final delta = event.scrollDelta.dy;
      if (delta == 0) return;
      final target = (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      // 到边界：不认领，让这一滚轮继续滚页面。
      if (target == position.pixels) return;
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (_) => position.jumpTo(target),
      );
    },
    child: child,
  );
}

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/widgets/hover_zoom_cover.dart';

void main() {
  testWidgets(
    'artwork zooms inside its frame only while the pointer is on it',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 100,
                height: 150,
                child: HoverBuilder(
                  builder: (context, hover) => HoverZoomCover(
                    drama: Drama(id: 'zoom', title: '缩放测试'),
                    hover: hover,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      double scale() =>
          tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
      double lean() => tester
          .widget<AnimatedContainer>(find.byType(AnimatedContainer))
          .transform!
          .storage[13];
      final frame = tester.getRect(
        find.byKey(const ValueKey('hover-zoom-frame')),
      );
      expect(scale(), 1.0);
      expect(lean(), 0.0);

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(pointer.removePointer);
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(tester.getCenter(find.byType(HoverBuilder)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(scale(), closeTo(1.08, 0.001));
      expect(lean(), closeTo(-2.0, 0.01));
      // The frame itself never moves: the zoom and the lean are inside it.
      expect(
        tester.getRect(find.byKey(const ValueKey('hover-zoom-frame'))),
        equals(frame),
      );

      await pointer.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 200));
      expect(scale(), 1.0);
      expect(lean(), 0.0);
    },
  );
}

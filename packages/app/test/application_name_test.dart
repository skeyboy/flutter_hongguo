import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/localization/application_name.dart';

void main() {
  test('application name follows language and explicit Chinese script', () {
    expect(applicationName(const Locale('en', 'US')), 'Hongguo');
    expect(applicationName(const Locale('fr')), 'Hongguo');
    expect(
      applicationNameForLocales([const Locale('fr'), const Locale('zh', 'TW')]),
      '紅果劇場',
    );
    expect(applicationNameForLocales([]), 'Hongguo');
    expect(applicationName(const Locale('zh', 'CN')), '红果剧场');
    expect(applicationName(const Locale('zh', 'SG')), '红果剧场');
    for (final country in ['TW', 'HK', 'MO']) {
      expect(applicationName(Locale('zh', country)), '紅果劇場');
    }
    expect(
      applicationName(
        const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
          countryCode: 'CN',
        ),
      ),
      '紅果劇場',
    );
    expect(
      applicationName(
        const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'TW',
        ),
      ),
      '红果剧场',
    );
  });
  testWidgets('app switcher name updates when OS language changes', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = [const Locale('en', 'US')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      ApplicationName(
        builder: (name) =>
            Directionality(textDirection: TextDirection.ltr, child: Text(name)),
      ),
    );
    expect(find.text('Hongguo'), findsOneWidget);
    tester.platformDispatcher.localesTestValue = [const Locale('zh', 'CN')];
    await tester.pump();
    expect(find.text('红果剧场'), findsOneWidget);
    tester.platformDispatcher.localesTestValue = [const Locale('zh', 'HK')];
    await tester.pump();
    expect(find.text('紅果劇場'), findsOneWidget);
  });
  testWidgets('shared branding and native window follow system language', (
    tester,
  ) async {
    final titles = <String>[];
    const channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'setTitle') {
        titles.add((call.arguments as Map)['title'] as String);
      }
      return null;
    });
    addTearDown(() {
      tester.platformDispatcher.clearLocalesTestValue();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    for (final entry in <Locale, String>{
      const Locale('en'): 'Hongguo',
      const Locale('zh', 'CN'): '红果剧场',
      const Locale('zh', 'TW'): '紅果劇場',
    }.entries) {
      tester.platformDispatcher.localesTestValue = [entry.key];
      await tester.pumpWidget(
        ApplicationName(
          builder: (_) => const Directionality(
            textDirection: TextDirection.ltr,
            child: _Branding(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget);
      expect(titles.last, entry.value);
    }
  });
}

class _Branding extends StatelessWidget {
  const _Branding();
  @override
  Widget build(BuildContext context) => Text(ApplicationName.of(context));
}

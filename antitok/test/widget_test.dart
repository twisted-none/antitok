import 'package:antitok/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('antitok/settings');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getSettings':
          return <String, Object>{'mode': 'schedule', 'intervals': '5,10,15'};
        case 'isServiceEnabled':
          return false;
        case 'saveSettings':
        case 'openAccessibilitySettings':
          return null;
      }
      throw PlatformException(code: 'not_implemented');
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('shows AntiTok settings screen', (tester) async {
    await tester.pumpWidget(const AntiTokApp());
    await tester.pump();

    expect(find.text('AntiTok'), findsOneWidget);
    expect(find.text('Сервис выключен'), findsOneWidget);
    expect(find.text('Карточка'), findsNothing);
    expect(find.text('Доступ'), findsOneWidget);
    expect(
      find.text('Плашки появятся через 5 минут, 15 минут, 30 минут'),
      findsOneWidget,
    );
  });

  testWidgets('uses accusative minute form for one minute', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getSettings':
          return <String, Object>{'mode': 'schedule', 'intervals': '1,20'};
        case 'isServiceEnabled':
          return false;
        case 'saveSettings':
        case 'openAccessibilitySettings':
          return null;
      }
      throw PlatformException(code: 'not_implemented');
    });

    await tester.pumpWidget(const AntiTokApp());
    await tester.pump();

    expect(
      find.text('Плашки появятся через 1 минуту, 21 минуту'),
      findsOneWidget,
    );
  });

  testWidgets('configures automatic close and adds a time window', (tester) async {
    await tester.pumpWidget(const AntiTokApp());
    await tester.pump();

    await tester.tap(find.text('Закрыть TikTok'));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    await tester.tap(find.text('Добавить промежуток'));
    await tester.pump();

    expect(find.text('Промежуток 1'), findsOneWidget);
    expect(find.text('С 09:00'), findsOneWidget);
    expect(find.text('До 18:00'), findsOneWidget);
    expect(find.text('Все дни'), findsOneWidget);

    await tester.tap(find.text('Все дни').last);
    await tester.pump();

    expect(find.text('Рабочие дни'), findsOneWidget);
  });
}

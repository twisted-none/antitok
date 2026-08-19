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
              return <String, Object>{
                'mode': 'schedule',
                'intervals': '5,10,15',
              };
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

  testWidgets('starts strict lock with selected duration', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    MethodCall? startCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getSettings':
              return <String, Object>{
                'mode': 'schedule',
                'intervals': '5,10,15',
                'lockDuration': 5,
                'lockActive': false,
                'lockEndMs': 0,
                'serviceConnected': true,
              };
            case 'isServiceEnabled':
              return true;
            case 'startLock':
              startCall = call;
              return <String, Object>{
                'lockEndMs': DateTime.now()
                    .add(const Duration(minutes: 12))
                    .millisecondsSinceEpoch,
              };
            case 'saveSettings':
            case 'openAccessibilitySettings':
              return null;
          }
          throw PlatformException(code: 'not_implemented');
        });

    await tester.pumpWidget(const AntiTokApp());
    await tester.pump();
    final durationField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Длительность, 1–180 минут',
      skipOffstage: false,
    );
    await tester.ensureVisible(durationField);
    await tester.enterText(durationField, '12');
    final startButton = find.text('Заблокировать TikTok', skipOffstage: false);
    await tester.ensureVisible(startButton);
    await tester.tap(startButton);
    await tester.pump();

    expect(startCall?.method, 'startLock');
    expect(startCall?.arguments, <String, Object>{'minutes': 12});
  });

  testWidgets('adds a weekday schedule window', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const AntiTokApp());
    await tester.pump();

    final addWindow = find.text('Добавить промежуток');
    await tester.tap(addWindow);
    await tester.pump();

    expect(find.text('Промежуток 1'), findsOneWidget);
    expect(find.text('С 09:00'), findsOneWidget);
    expect(find.text('До 18:00'), findsOneWidget);

    final allDays = find.text('Все дни');
    await tester.tap(allDays);
    await tester.pump();
    await tester.tap(find.text('Рабочие дни'));
    await tester.tap(find.text('Готово'));
    await tester.pump();

    expect(find.text('Пн, Вт, Ср, Чт, Пт'), findsOneWidget);
  });

  testWidgets('saves close TikTok timeout action', (tester) async {
    MethodCall? saveCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getSettings') {
            return <String, Object>{
              'mode': 'once',
              'intervals': '5',
              'timeoutAction': 'prompt',
              'lockDuration': 5,
            };
          }
          if (call.method == 'isServiceEnabled') return false;
          if (call.method == 'saveSettings') {
            saveCall = call;
            return null;
          }
          return null;
        });
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const AntiTokApp());
    await tester.pump();
    await tester.tap(find.text('Закрыть TikTok'));
    await tester.tap(find.text('Сохранить'));
    await tester.pump();

    expect(
      (saveCall?.arguments as Map<Object?, Object?>?)?['timeoutAction'],
      'close',
    );
  });
}

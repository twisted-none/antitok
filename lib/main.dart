import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const AntiTokApp());

enum ReminderMode { schedule, once, disabled }

enum TimeoutAction { prompt, close }

const _allDaysMask = 127;
const _weekdaysMask = 31;
const _dayBits = [1, 2, 4, 8, 16, 32, 64];
const _dayShortNames = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

class TimeWindowConfig {
  const TimeWindowConfig({
    required this.startMinutes,
    required this.endMinutes,
    required this.daysMask,
  });

  final int startMinutes;
  final int endMinutes;
  final int daysMask;

  TimeWindowConfig copyWith({
    int? startMinutes,
    int? endMinutes,
    int? daysMask,
  }) {
    return TimeWindowConfig(
      startMinutes: startMinutes ?? this.startMinutes,
      endMinutes: endMinutes ?? this.endMinutes,
      daysMask: daysMask ?? this.daysMask,
    );
  }

  String serialize() => '$startMinutes-$endMinutes-$daysMask';

  static TimeWindowConfig? parse(String raw) {
    final parts = raw.split('-');
    if (parts.length != 3) return null;
    final start = int.tryParse(parts[0]);
    final end = int.tryParse(parts[1]);
    final days = int.tryParse(parts[2]);
    if (start == null || end == null || days == null) return null;
    if (!start.isBetween(0, 1439) ||
        !end.isBetween(0, 1439) ||
        start == end ||
        days & _allDaysMask == 0) {
      return null;
    }
    return TimeWindowConfig(
      startMinutes: start,
      endMinutes: end,
      daysMask: days & _allDaysMask,
    );
  }
}

extension on int {
  bool isBetween(int min, int max) => this >= min && this <= max;
}

const _bg = Colors.black;
const _panel = Color(0xFF080808);
const _line = Color(0xFF242424);
const _text = Color(0xFFF5F5F5);
const _muted = Color(0xFF9B9B9B);
const _accent = Color(0xFFFFFFFF);

class AntiTokApp extends StatelessWidget {
  const AntiTokApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: Brightness.dark,
      surface: _bg,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AntiTok',
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: _bg,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: _bg,
          foregroundColor: _text,
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _panel,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: _line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: _line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: _accent, width: 1.4),
          ),
          labelStyle: const TextStyle(color: _muted),
          helperStyle: const TextStyle(color: _muted),
        ),
      ),
      home: const SettingsScreen(),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('antitok/settings');
  final _scheduleController = TextEditingController(text: '5, 10, 15');
  final _onceController = TextEditingController(text: '5');
  final _lockController = TextEditingController(text: '5');
  ReminderMode _mode = ReminderMode.schedule;
  TimeoutAction _timeoutAction = TimeoutAction.prompt;
  ReminderMode _savedMode = ReminderMode.schedule;
  TimeoutAction _savedTimeoutAction = TimeoutAction.prompt;
  List<int> _savedIntervals = const [5, 10, 15];
  List<TimeWindowConfig> _windows = const [];
  List<TimeWindowConfig> _savedWindows = const [];
  bool _autoLockAfterForcedExit = false;
  bool _serviceEnabled = false;
  bool _serviceConnected = false;
  bool _saving = false;
  bool _startingLock = false;
  bool _lockActive = false;
  int _lockEndMs = 0;
  int _lockRemainingAtLoadMs = 0;
  int _loadRequest = 0;
  final Stopwatch _lockStopwatch = Stopwatch();
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleController.addListener(_refreshSchedulePreview);
    _onceController.addListener(_refreshOncePreview);
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickLock());
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scheduleController.removeListener(_refreshSchedulePreview);
    _onceController.removeListener(_refreshOncePreview);
    _lockTimer?.cancel();
    _scheduleController.dispose();
    _onceController.dispose();
    _lockController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final request = ++_loadRequest;
    final data = await _channel.invokeMapMethod<String, Object?>('getSettings');
    final mode = data?['mode'] as String? ?? 'schedule';
    final timeoutAction = data?['timeoutAction'] as String? ?? 'prompt';
    final intervals = data?['intervals'] as String? ?? '5,10,15';
    final lockDuration = data?['lockDuration'] as int? ?? 5;
    final windows = data?['windows'] as String? ?? '';
    final autoLock = data?['autoLockAfterForcedExit'] as bool? ?? false;
    final lockActive = data?['lockActive'] as bool? ?? false;
    final lockEndMs = data?['lockEndMs'] as int? ?? 0;
    final lockRemainingMs = data?['lockRemainingMs'] as int? ?? 0;
    final serviceConnected = data?['serviceConnected'] as bool? ?? false;
    final intervalParts = intervals.split(',');
    final firstInterval = intervalParts.isEmpty ? '5' : intervalParts.first;
    if (!mounted || request != _loadRequest) return;
    _lockStopwatch
      ..reset()
      ..start();
    setState(() {
      _mode = _modeFromName(mode);
      _timeoutAction = timeoutAction == 'close'
          ? TimeoutAction.close
          : TimeoutAction.prompt;
      _savedMode = _mode;
      _savedTimeoutAction = _timeoutAction;
      _savedIntervals = _parseIntervalText(intervals) ?? const [5, 10, 15];
      _windows = _parseWindows(windows);
      _savedWindows = List.of(_windows);
      _autoLockAfterForcedExit = autoLock;
      _scheduleController.text = intervals.replaceAll(',', ', ');
      _onceController.text = firstInterval.trim();
      _lockController.text = lockDuration.toString();
      _lockActive = lockActive;
      _lockEndMs = lockEndMs;
      _lockRemainingAtLoadMs = lockRemainingMs;
      _serviceConnected = serviceConnected;
    });
    await _refreshServiceState();
  }

  void _tickLock() {
    if (!mounted || !_lockActive) return;
    if (_remainingLockMs <= 0) {
      setState(() => _lockActive = false);
    } else {
      setState(() {});
    }
  }

  Future<void> _refreshServiceState() async {
    final enabled = await _channel.invokeMethod<bool>('isServiceEnabled');
    if (mounted) setState(() => _serviceEnabled = enabled ?? false);
  }

  void _refreshSchedulePreview() {
    if (mounted && _mode == ReminderMode.schedule) setState(() {});
  }

  void _refreshOncePreview() {
    if (mounted && _mode == ReminderMode.once) setState(() {});
  }

  List<int>? _parseSchedule() {
    return _parseIntervalText(_scheduleController.text);
  }

  List<int>? _parseIntervalText(String text) {
    final values = text
        .split(',')
        .map((part) => int.tryParse(part.trim()))
        .toList();
    if (values.isEmpty || values.any((value) => value == null || value <= 0)) {
      return null;
    }
    return values.cast<int>();
  }

  int? _parseOnce() {
    final value = int.tryParse(_onceController.text.trim());
    return value != null && value > 0 ? value : null;
  }

  ReminderMode _modeFromName(String mode) {
    return switch (mode) {
      'once' => ReminderMode.once,
      'disabled' => ReminderMode.disabled,
      _ => ReminderMode.schedule,
    };
  }

  List<TimeWindowConfig> _parseWindows(String raw) => raw
      .split(';')
      .map(TimeWindowConfig.parse)
      .whereType<TimeWindowConfig>()
      .toList();

  String _serializeWindows(List<TimeWindowConfig> windows) =>
      windows.map((window) => window.serialize()).join(';');

  Future<void> _save() async {
    final lockDuration = int.tryParse(_lockController.text.trim());
    if (lockDuration == null || lockDuration < 1 || lockDuration > 180) {
      _showMessage('Введите время блокировки от 1 до 180 минут');
      return;
    }
    final intervals = switch (_mode) {
      ReminderMode.schedule => _parseSchedule(),
      ReminderMode.once => [_parseOnce()].whereType<int>().toList(),
      ReminderMode.disabled =>
        _savedIntervals.isEmpty ? const [5] : _savedIntervals,
    };
    if (intervals == null || intervals.isEmpty) {
      _showMessage(
        _mode == ReminderMode.schedule
            ? 'Введите интервалы через запятую, например 5, 10, 15'
            : 'Введите количество минут больше нуля',
      );
      return;
    }
    if (_windows.any((window) => window.startMinutes == window.endMinutes)) {
      _showMessage('Начало и окончание промежутка не должны совпадать');
      return;
    }
    setState(() => _saving = true);
    try {
      await _channel.invokeMethod<void>('saveSettings', {
        'mode': _mode.name,
        'intervals': intervals.join(','),
        'windows': _serializeWindows(_windows),
        'lockDuration': lockDuration,
        'autoLockAfterForcedExit': _autoLockAfterForcedExit,
        'timeoutAction': _timeoutAction.name,
      });
      if (mounted) {
        setState(() {
          _savedMode = _mode;
          _savedTimeoutAction = _timeoutAction;
          _savedIntervals = intervals;
          _savedWindows = List.of(_windows);
        });
        _showMessage('Настройки сохранены');
      }
    } on PlatformException catch (error) {
      _showMessage(error.message ?? 'Не удалось сохранить настройки');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openAccessibilitySettings() async {
    await _channel.invokeMethod<void>('openAccessibilitySettings');
  }

  Future<void> _startLock() async {
    final minutes = int.tryParse(_lockController.text.trim());
    if (minutes == null || minutes < 1 || minutes > 180) {
      _showMessage('Введите время от 1 до 180 минут');
      return;
    }
    if (!_serviceConnected) {
      _showMessage('Сначала включите доступ AntiTok и вернитесь в приложение');
      return;
    }
    setState(() => _startingLock = true);
    try {
      await _channel.invokeMethod<Object?>('startLock', {'minutes': minutes});
      await _load();
      _showMessage('TikTok заблокирован на ${_formatMinutes(minutes)}');
    } on PlatformException catch (error) {
      _showMessage(error.message ?? 'Не удалось запустить блокировку');
    } finally {
      if (mounted) setState(() => _startingLock = false);
    }
  }

  Future<void> _requestPinWidget() async {
    final requested =
        await _channel.invokeMethod<bool>('requestPinWidget') ?? false;
    if (!requested) {
      _showMessage(
        'Добавьте виджет AntiTok через меню виджетов вашего лаунчера',
      );
    }
  }

  String _remainingLockText() {
    final remaining = Duration(milliseconds: _remainingLockMs);
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final seconds = remaining.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  int get _remainingLockMs =>
      (_lockRemainingAtLoadMs - _lockStopwatch.elapsedMilliseconds).clamp(
        0,
        1 << 31,
      );

  String _lockEndText() {
    if (_lockEndMs <= 0) return '';
    final end = DateTime.fromMillisecondsSinceEpoch(_lockEndMs);
    return '${end.hour.toString().padLeft(2, '0')}:'
        '${end.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickWindowTime(int index, bool isStart) async {
    final window = _windows[index];
    final source = isStart ? window.startMinutes : window.endMinutes;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: source ~/ 60, minute: source % 60),
    );
    if (picked == null || !mounted) return;
    final minutes = picked.hour * 60 + picked.minute;
    setState(() {
      _windows[index] = isStart
          ? window.copyWith(startMinutes: minutes)
          : window.copyWith(endMinutes: minutes);
    });
  }

  Future<void> _pickWindowDays(int index) async {
    var mask = _windows[index].daysMask;
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void toggle(int bit) {
            setDialogState(() {
              final next = mask ^ bit;
              mask = next == 0 ? bit : next;
            });
          }

          return AlertDialog(
            backgroundColor: _panel,
            title: const Text('Дни недели'),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _DayPresetChip(
                          label: 'Все дни',
                          selected: mask == _allDaysMask,
                          onSelected: () =>
                              setDialogState(() => mask = _allDaysMask),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _DayPresetChip(
                          label: 'Рабочие дни',
                          selected: mask == _weekdaysMask,
                          onSelected: () =>
                              setDialogState(() => mask = _weekdaysMask),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: 4,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.45,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      for (var i = 0; i < _dayBits.length; i++)
                        _DayPresetChip(
                          label: _dayShortNames[i],
                          selected: mask & _dayBits[i] != 0,
                          onSelected: () => toggle(_dayBits[i]),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, mask),
                child: const Text('Готово'),
              ),
            ],
          );
        },
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _windows[index] = _windows[index].copyWith(daysMask: result);
    });
  }

  void _addWindow() {
    setState(() {
      _windows = [
        ..._windows,
        const TimeWindowConfig(
          startMinutes: 9 * 60,
          endMinutes: 18 * 60,
          daysMask: _allDaysMask,
        ),
      ];
    });
  }

  void _removeWindow(int index) {
    setState(() => _windows = [..._windows]..removeAt(index));
  }

  String _formatTime(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  String _formatDays(int mask) {
    if (mask == _allDaysMask) return 'Все дни';
    final names = <String>[];
    for (var i = 0; i < _dayBits.length; i++) {
      if (mask & _dayBits[i] != 0) names.add(_dayShortNames[i]);
    }
    return names.join(', ');
  }

  String _savedWindowsText() {
    if (_savedWindows.isEmpty) return 'Расписание: всегда активно';
    return _savedWindows
        .map(
          (window) =>
              '${_formatTime(window.startMinutes)}–'
              '${_formatTime(window.endMinutes)} (${_formatDays(window.daysMask)})',
        )
        .join('\n');
  }

  String _savedActionText() {
    if (_savedMode == ReminderMode.disabled) {
      return 'Действие по таймеру не применяется';
    }
    return _savedTimeoutAction == TimeoutAction.close
        ? 'По таймеру: закрывать TikTok'
        : 'По таймеру: показывать плашку';
  }

  String _schedulePreview() {
    final intervals = _parseSchedule();
    if (intervals == null) return 'Введите числа через запятую';
    var total = 0;
    final totals = <String>[];
    for (final interval in intervals) {
      total += interval;
      totals.add(_formatMinutes(total));
    }
    return 'Плашки появятся через ${totals.join(', ')}';
  }

  String _minuteWord(int value) {
    final mod100 = value % 100;
    final mod10 = value % 10;
    if (mod100 >= 11 && mod100 <= 14) return 'минут';
    if (mod10 == 1) return 'минуту';
    if (mod10 >= 2 && mod10 <= 4) return 'минуты';
    return 'минут';
  }

  String _formatMinutes(int value) {
    return '$value ${_minuteWord(value)}';
  }

  String _savedModeText() {
    return switch (_savedMode) {
      ReminderMode.schedule => 'Несколько раз',
      ReminderMode.once => 'Один раз',
      ReminderMode.disabled => 'Отключено',
    };
  }

  String _savedSettingsText() {
    if (_savedMode == ReminderMode.disabled) {
      return 'Плашки поверх TikTok не показываются';
    }
    if (_savedMode == ReminderMode.once) {
      return 'Напомнить через ${_formatMinutes(_savedIntervals.first)}';
    }
    var total = 0;
    final totals = <String>[];
    for (final interval in _savedIntervals) {
      total += interval;
      totals.add(_formatMinutes(total));
    }
    return 'Плашки через ${totals.join(', ')}';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AntiTok')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          _StatusPanel(
            enabled: _serviceEnabled,
            onOpenAccessibility: _openAccessibilitySettings,
          ),
          const SizedBox(height: 28),
          Text('Режим', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          _ModePicker(
            value: _mode,
            onChanged: (value) => setState(() => _mode = value),
          ),
          if (_mode != ReminderMode.disabled) ...[
            const SizedBox(height: 20),
            Text(
              'Действие по таймеру',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            _TimeoutActionPicker(
              value: _timeoutAction,
              onChanged: (value) => setState(() => _timeoutAction = value),
            ),
          ],
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: switch (_mode) {
              ReminderMode.schedule => _ScheduleField(
                controller: _scheduleController,
                previewText: _schedulePreview(),
              ),
              ReminderMode.once => _OnceField(
                controller: _onceController,
                minuteWord: _minuteWord(_parseOnce() ?? 0),
              ),
              ReminderMode.disabled => const _DisabledField(),
            },
          ),
          if (_mode != ReminderMode.disabled) ...[
            const SizedBox(height: 22),
            _WindowsPanel(
              windows: _windows,
              formatTime: _formatTime,
              formatDays: _formatDays,
              onAdd: _addWindow,
              onPickStart: (index) => _pickWindowTime(index, true),
              onPickEnd: (index) => _pickWindowTime(index, false),
              onPickDays: _pickWindowDays,
              onRemove: _removeWindow,
            ),
          ],
          const SizedBox(height: 28),
          Text(
            'Строгая блокировка',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          _LockPanel(
            controller: _lockController,
            active: _lockActive,
            remaining: _remainingLockText(),
            endTime: _lockEndText(),
            starting: _startingLock,
            autoLockAfterForcedExit: _autoLockAfterForcedExit,
            onAutoLockChanged: (value) =>
                setState(() => _autoLockAfterForcedExit = value),
            onStart: _startLock,
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _text,
              foregroundColor: _bg,
              minimumSize: const Size.fromHeight(56),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_rounded),
            label: Text(_saving ? 'Сохранение...' : 'Сохранить'),
          ),
          const SizedBox(height: 18),
          _CurrentSettingsPanel(
            mode: _savedModeText(),
            details: _savedSettingsText(),
            action: _savedActionText(),
            windows: _savedWindowsText(),
          ),
          const SizedBox(height: 28),
          Text('Виджет', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          _WidgetPanel(onAdd: _requestPinWidget),
        ],
      ),
    );
  }
}

class _LockPanel extends StatelessWidget {
  const _LockPanel({
    required this.controller,
    required this.active,
    required this.remaining,
    required this.endTime,
    required this.starting,
    required this.autoLockAfterForcedExit,
    required this.onAutoLockChanged,
    required this.onStart,
  });

  final TextEditingController controller;
  final bool active;
  final String remaining;
  final String endTime;
  final bool starting;
  final bool autoLockAfterForcedExit;
  final ValueChanged<bool> onAutoLockChanged;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (active) ...[
            const Text(
              'Блокировка активна',
              style: TextStyle(
                color: Color(0xFF38E07B),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$remaining · до $endTime',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 14),
          ],
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Длительность, 1–180 минут',
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Досрочная отмена возможна только через режим «Отключить» или виджет.',
            style: TextStyle(color: _muted, height: 1.35),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Блокировать после выхода через AntiTok'),
            subtitle: const Text(
              'После выбора «Выйти» запустится таймер указанной длительности.',
              style: TextStyle(color: _muted),
            ),
            value: autoLockAfterForcedExit,
            onChanged: onAutoLockChanged,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: starting ? null : onStart,
            icon: const Icon(Icons.lock_clock_rounded),
            label: Text(
              starting
                  ? 'Запуск...'
                  : active
                  ? 'Запустить заново'
                  : 'Заблокировать TikTok',
            ),
          ),
        ],
      ),
    );
  }
}

class _WidgetPanel extends StatelessWidget {
  const _WidgetPanel({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Кнопка 1×1 включает последний режим или полностью выключает защиту.',
            style: TextStyle(color: _muted, height: 1.35),
          ),
          const SizedBox(height: 16),
          _GhostButton(
            icon: Icons.widgets_rounded,
            label: 'Добавить виджет',
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

class _CurrentSettingsPanel extends StatelessWidget {
  const _CurrentSettingsPanel({
    required this.mode,
    required this.details,
    required this.action,
    required this.windows,
  });

  final String mode;
  final String details;
  final String action;
  final String windows;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Текущие настройки',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.tune_rounded, color: _muted, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(mode, style: const TextStyle(color: _text)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.touch_app_rounded, color: _muted, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(action, style: const TextStyle(color: _muted)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.event_rounded, color: _muted, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(windows, style: const TextStyle(color: _muted)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.schedule_rounded, color: _muted, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(details, style: const TextStyle(color: _muted)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.enabled,
    required this.onOpenAccessibility,
  });

  final bool enabled;
  final VoidCallback onOpenAccessibility;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                enabled ? Icons.check_circle_rounded : Icons.lock_rounded,
                color: enabled ? Colors.white : const Color(0xFFFFB84D),
              ),
              const SizedBox(width: 10),
              Text(
                enabled ? 'Сервис включен' : 'Сервис выключен',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            'Откройте доступ, чтобы AntiTok видел запуск TikTok и мог показывать плашки.',
            style: TextStyle(color: _muted, height: 1.35),
          ),
          const SizedBox(height: 16),
          _GhostButton(
            icon: Icons.accessibility_new_rounded,
            label: 'Доступ',
            onPressed: onOpenAccessibility,
          ),
        ],
      ),
    );
  }
}

class _ModePicker extends StatelessWidget {
  const _ModePicker({required this.value, required this.onChanged});

  final ReminderMode value;
  final ValueChanged<ReminderMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _panel,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _ModeTile(
                active: value == ReminderMode.schedule,
                icon: Icons.repeat_rounded,
                label: 'Несколько раз',
                onTap: () => onChanged(ReminderMode.schedule),
              ),
              _ModeTile(
                active: value == ReminderMode.once,
                icon: Icons.looks_one_rounded,
                label: 'Один раз',
                onTap: () => onChanged(ReminderMode.once),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _ModeTile(
                active: value == ReminderMode.disabled,
                icon: Icons.block_rounded,
                label: 'Отключить',
                onTap: () => onChanged(ReminderMode.disabled),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.active,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool active;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 48,
          decoration: BoxDecoration(
            color: active ? _text : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: active ? _bg : _muted),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? _bg : _muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeoutActionPicker extends StatelessWidget {
  const _TimeoutActionPicker({required this.value, required this.onChanged});

  final TimeoutAction value;
  final ValueChanged<TimeoutAction> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _panel,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          _ActionTile(
            active: value == TimeoutAction.prompt,
            icon: Icons.chat_bubble_outline_rounded,
            label: 'Показать плашку',
            onTap: () => onChanged(TimeoutAction.prompt),
          ),
          _ActionTile(
            active: value == TimeoutAction.close,
            icon: Icons.logout_rounded,
            label: 'Закрыть TikTok',
            onTap: () => onChanged(TimeoutAction.close),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.active,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool active;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 52,
          decoration: BoxDecoration(
            color: active ? _text : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: active ? _bg : _muted),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? _bg : _muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowsPanel extends StatelessWidget {
  const _WindowsPanel({
    required this.windows,
    required this.formatTime,
    required this.formatDays,
    required this.onAdd,
    required this.onPickStart,
    required this.onPickEnd,
    required this.onPickDays,
    required this.onRemove,
  });

  final List<TimeWindowConfig> windows;
  final String Function(int) formatTime;
  final String Function(int) formatDays;
  final VoidCallback onAdd;
  final ValueChanged<int> onPickStart;
  final ValueChanged<int> onPickEnd;
  final ValueChanged<int> onPickDays;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Расписание работы',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'Если список пуст, правила работают всегда.',
            style: TextStyle(color: _muted),
          ),
          for (var index = 0; index < windows.length; index++) ...[
            const SizedBox(height: 14),
            _WindowTile(
              index: index,
              window: windows[index],
              formatTime: formatTime,
              formatDays: formatDays,
              onPickStart: () => onPickStart(index),
              onPickEnd: () => onPickEnd(index),
              onPickDays: () => onPickDays(index),
              onRemove: () => onRemove(index),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Добавить промежуток'),
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowTile extends StatelessWidget {
  const _WindowTile({
    required this.index,
    required this.window,
    required this.formatTime,
    required this.formatDays,
    required this.onPickStart,
    required this.onPickEnd,
    required this.onPickDays,
    required this.onRemove,
  });

  final int index;
  final TimeWindowConfig window;
  final String Function(int) formatTime;
  final String Function(int) formatDays;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;
  final VoidCallback onPickDays;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
      decoration: BoxDecoration(
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Промежуток ${index + 1}',
                  style: const TextStyle(
                    color: _text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Удалить промежуток',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline_rounded, color: _muted),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: _WindowButton(
                  icon: Icons.schedule_rounded,
                  label: 'С ${formatTime(window.startMinutes)}',
                  onPressed: onPickStart,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _WindowButton(
                  icon: Icons.schedule_rounded,
                  label: 'До ${formatTime(window.endMinutes)}',
                  onPressed: onPickEnd,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: _WindowButton(
              icon: Icons.calendar_month_rounded,
              label: formatDays(window.daysMask),
              onPressed: onPickDays,
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label, overflow: TextOverflow.ellipsis),
    );
  }
}

class _DayPresetChip extends StatelessWidget {
  const _DayPresetChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _ScheduleField extends StatelessWidget {
  const _ScheduleField({required this.controller, required this.previewText});

  final TextEditingController controller;
  final String previewText;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      key: const ValueKey('schedule'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            keyboardType: TextInputType.text,
            style: const TextStyle(color: _text, fontSize: 18),
            decoration: const InputDecoration(labelText: 'Интервалы в минутах'),
          ),
          const SizedBox(height: 10),
          Text(previewText, style: const TextStyle(color: _muted)),
        ],
      ),
    );
  }
}

class _OnceField extends StatelessWidget {
  const _OnceField({required this.controller, required this.minuteWord});

  final TextEditingController controller;
  final String minuteWord;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      key: const ValueKey('once'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Напомнить через',
                style: TextStyle(color: _muted, fontSize: 18),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 72,
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _text, fontSize: 20),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                minuteWord,
                style: const TextStyle(color: _muted, fontSize: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'После согласия в этой сессии больше не спрашивать',
            style: TextStyle(color: _muted),
          ),
        ],
      ),
    );
  }
}

class _DisabledField extends StatelessWidget {
  const _DisabledField();

  @override
  Widget build(BuildContext context) {
    return const _Panel(
      key: ValueKey('disabled'),
      child: Row(
        children: [
          Icon(Icons.notifications_off_rounded, color: _muted, size: 22),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Плашки поверх TikTok отключены. Сервис останется включенным, но уведомления показываться не будут.',
              style: TextStyle(color: _muted, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _panel,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(22),
      ),
      child: child,
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: _text,
        side: const BorderSide(color: _line),
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 19),
      label: Text(label, overflow: TextOverflow.ellipsis),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const AntiTokApp());

enum ReminderMode { schedule, once, disabled }

enum TimeoutAction { prompt, close }

const _bg = Colors.black;
const _panel = Color(0xFF080808);
const _line = Color(0xFF242424);
const _text = Color(0xFFF5F5F5);
const _muted = Color(0xFF9B9B9B);
const _accent = Color(0xFFFFFFFF);

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

  TimeWindowConfig copyWith({int? startMinutes, int? endMinutes, int? daysMask}) {
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
    if (start < 0 || start > 1439 || end < 0 || end > 1439 || start == end) {
      return null;
    }
    if ((days & _allDaysMask) == 0) return null;
    return TimeWindowConfig(
      startMinutes: start,
      endMinutes: end,
      daysMask: days & _allDaysMask,
    );
  }
}

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
  ReminderMode _mode = ReminderMode.schedule;
  TimeoutAction _timeoutAction = TimeoutAction.prompt;
  List<TimeWindowConfig> _windows = const [];
  ReminderMode _savedMode = ReminderMode.schedule;
  TimeoutAction _savedTimeoutAction = TimeoutAction.prompt;
  List<int> _savedIntervals = const [5, 10, 15];
  List<TimeWindowConfig> _savedWindows = const [];
  bool _serviceEnabled = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleController.addListener(_refreshSchedulePreview);
    _onceController.addListener(_refreshOncePreview);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scheduleController.removeListener(_refreshSchedulePreview);
    _onceController.removeListener(_refreshOncePreview);
    _scheduleController.dispose();
    _onceController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshServiceState();
  }

  Future<void> _load() async {
    final data = await _channel.invokeMapMethod<String, Object?>('getSettings');
    final mode = data?['mode'] as String? ?? 'schedule';
    final intervals = data?['intervals'] as String? ?? '5,10,15';
    final timeoutAction = data?['timeoutAction'] as String? ?? 'prompt';
    final windows = data?['windows'] as String? ?? '';
    final intervalParts = intervals.split(',');
    final firstInterval = intervalParts.isEmpty ? '5' : intervalParts.first;
    setState(() {
      _mode = _modeFromName(mode);
      _timeoutAction = _actionFromName(timeoutAction);
      _windows = _parseWindows(windows);
      _savedMode = _mode;
      _savedTimeoutAction = _timeoutAction;
      _savedIntervals = _parseIntervalText(intervals) ?? const [5, 10, 15];
      _savedWindows = _windows;
      _scheduleController.text = intervals.replaceAll(',', ', ');
      _onceController.text = firstInterval.trim();
    });
    await _refreshServiceState();
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
    final values = text.split(',').map((part) => int.tryParse(part.trim())).toList();
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

  TimeoutAction _actionFromName(String action) {
    return action == 'close' ? TimeoutAction.close : TimeoutAction.prompt;
  }

  List<TimeWindowConfig> _parseWindows(String raw) {
    return raw.split(';').map(TimeWindowConfig.parse).whereType<TimeWindowConfig>().toList();
  }

  String _serializeWindows(List<TimeWindowConfig> windows) {
    return windows.map((window) => window.serialize()).join(';');
  }

  Future<void> _save() async {
    final intervals = switch (_mode) {
      ReminderMode.schedule => _parseSchedule(),
      ReminderMode.once => [_parseOnce()].whereType<int>().toList(),
      ReminderMode.disabled => _savedIntervals.isEmpty ? const [5] : _savedIntervals,
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
      _showMessage('Время начала и окончания промежутка не должно совпадать');
      return;
    }
    setState(() => _saving = true);
    await _channel.invokeMethod<void>('saveSettings', {
      'mode': _mode.name,
      'intervals': intervals.join(','),
      'timeoutAction': _timeoutAction.name,
      'windows': _serializeWindows(_windows),
    });
    if (mounted) {
      setState(() {
        _saving = false;
        _savedMode = _mode;
        _savedTimeoutAction = _timeoutAction;
        _savedIntervals = intervals;
        _savedWindows = List.of(_windows);
      });
      _showMessage('Настройки сохранены');
    }
  }

  Future<void> _openAccessibilitySettings() async {
    await _channel.invokeMethod<void>('openAccessibilitySettings');
  }

  Future<void> _pickWindowTime(int index, bool isStart) async {
    final window = _windows[index];
    final source = isStart ? window.startMinutes : window.endMinutes;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: source ~/ 60, minute: source % 60),
      builder: (context, child) {
        return Theme(data: Theme.of(context), child: child ?? const SizedBox.shrink());
      },
    );
    if (picked == null) return;
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
      builder: (context) {
        return StatefulBuilder(
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
                            onSelected: () => setDialogState(() => mask = _allDaysMask),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _DayPresetChip(
                            label: 'Рабочие дни',
                            selected: mask == _weekdaysMask,
                            onSelected: () => setDialogState(() => mask = _weekdaysMask),
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
        );
      },
    );
    if (result == null) return;
    setState(() {
      _windows[index] = _windows[index].copyWith(daysMask: result);
    });
  }

  void _addWindow() {
    setState(() {
      _windows = [
        ..._windows,
        const TimeWindowConfig(startMinutes: 9 * 60, endMinutes: 18 * 60, daysMask: _allDaysMask),
      ];
    });
  }

  void _removeWindow(int index) {
    setState(() {
      _windows = [..._windows]..removeAt(index);
    });
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

  String _formatTime(int minutes) {
    final hour = (minutes ~/ 60).toString().padLeft(2, '0');
    final minute = (minutes % 60).toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _formatDays(int mask) {
    if (mask == _allDaysMask) return 'Все дни';
    final names = <String>[];
    for (var i = 0; i < _dayBits.length; i++) {
      if (mask & _dayBits[i] != 0) names.add(_dayShortNames[i]);
    }
    return names.join(', ');
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

  String _savedActionText() {
    return _savedTimeoutAction == TimeoutAction.close
        ? 'По таймеру: закрывать TikTok'
        : 'По таймеру: показывать плашку';
  }

  String _savedWindowsText() {
    if (_savedWindows.isEmpty) return 'Промежутки: всегда активно';
    return _savedWindows
        .map((window) => '${_formatTime(window.startMinutes)}-${_formatTime(window.endMinutes)} (${_formatDays(window.daysMask)})')
        .join('\n');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
            Text('Действие по таймеру', style: Theme.of(context).textTheme.titleLarge),
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
          Text('Текущие настройки', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.tune_rounded, color: _muted, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(mode, style: const TextStyle(color: _text))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.schedule_rounded, color: _muted, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(details, style: const TextStyle(color: _muted))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.touch_app_rounded, color: _muted, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(action, style: const TextStyle(color: _muted))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.event_rounded, color: _muted, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(windows, style: const TextStyle(color: _muted))),
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
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: active ? _text : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: active ? _bg : _muted),
              const SizedBox(width: 6),
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
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onSelected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF35545B) : const Color(0xFF111111),
          border: Border.all(color: selected ? const Color(0xFF52747B) : _line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? Icons.check_rounded : Icons.add_rounded,
              size: 17,
              color: selected ? _text : _muted,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? _text : _muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
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
          Text('Промежутки', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text(
            'Если список пуст, таймер работает всегда.',
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
                  style: const TextStyle(color: _text, fontWeight: FontWeight.w700),
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
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label, overflow: TextOverflow.ellipsis),
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
            decoration: const InputDecoration(
              labelText: 'Интервалы в минутах',
            ),
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
              Text(minuteWord, style: const TextStyle(color: _muted, fontSize: 18)),
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

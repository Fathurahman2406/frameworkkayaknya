import 'dart:async';
import 'dart:math';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const GamifiedHabitApp());
}

class GamifiedHabitApp extends StatelessWidget {
  const GamifiedHabitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Quest Habit Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        scaffoldBackgroundColor: const Color(0xFFF6F3FF),
        useMaterial3: true,
      ),
      home: const SetupDailyQuestsPage(),
    );
  }
}

// ==========================================
// MODEL & HELPER
// ==========================================
int _idCounter = 0;
String _newId() => '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

// Daftar ikon yang bisa dipilih user saat membuat quest
const List<IconData> kQuestIcons = [
  Icons.water_drop,
  Icons.menu_book,
  Icons.fitness_center,
  Icons.code,
  Icons.self_improvement,
  Icons.bedtime,
  Icons.restaurant,
  Icons.cleaning_services,
  Icons.music_note,
  Icons.brush,
];

// Jenis quest menentukan cara quest diselesaikan:
// - general  : langsung dicentang
// - exercise : pilih olahraga -> timer hitung mundur -> selesai
// - reading  : tulis catatan / ringkasan bacaan -> selesai
enum QuestType { general, exercise, reading }

extension QuestTypeInfo on QuestType {
  String get label {
    switch (this) {
      case QuestType.general:
        return 'Umum';
      case QuestType.exercise:
        return 'Olahraga';
      case QuestType.reading:
        return 'Baca Buku';
    }
  }

  String get hint {
    switch (this) {
      case QuestType.general:
        return 'Langsung dicentang';
      case QuestType.exercise:
        return 'Pilih olahraga & timer hitung mundur';
      case QuestType.reading:
        return 'Tulis ringkasan / pengalaman membaca';
    }
  }

  IconData get icon {
    switch (this) {
      case QuestType.general:
        return Icons.check_circle_outline;
      case QuestType.exercise:
        return Icons.timer;
      case QuestType.reading:
        return Icons.edit_note;
    }
  }
}

class Quest {
  final String id;
  String title;
  bool isCompleted;
  int xpReward;
  int earnedXP; // XP yang benar-benar didapat (termasuk bonus streak)
  bool isMainQuest; // True = Misi Utama, False = Side Quest
  IconData icon;
  QuestType type;
  String? detail; // Hasil penyelesaian: olahraga + durasi, atau catatan bacaan

  Quest({
    String? id,
    required this.title,
    this.isCompleted = false,
    required this.xpReward,
    required this.isMainQuest,
    this.icon = Icons.star,
    this.earnedXP = 0,
    this.type = QuestType.general,
    this.detail,
  }) : id = id ?? _newId();

  // Salinan baru (belum selesai) untuk dipakai di dashboard
  Quest copyFresh({bool? main}) => Quest(
    title: title,
    xpReward: xpReward,
    isMainQuest: main ?? isMainQuest,
    icon: icon,
    type: type,
  );
}

// Perhitungan level berbasis total XP, sehingga membatalkan centang
// bisa menurunkan level dengan benar.
int xpNeededForLevel(int level) => (100 * pow(1.2, level - 1)).round();

class LevelInfo {
  final int level;
  final int currentXP;
  final int maxXP;
  LevelInfo(this.level, this.currentXP, this.maxXP);

  factory LevelInfo.fromTotal(int totalXP) {
    int level = 1;
    int remaining = totalXP;
    while (remaining >= xpNeededForLevel(level)) {
      remaining -= xpNeededForLevel(level);
      level++;
    }
    return LevelInfo(level, remaining, xpNeededForLevel(level));
  }
}

String titleForLevel(int level) {
  const titles = [
    'Pemula',
    'Petualang',
    'Pejuang',
    'Ksatria',
    'Pahlawan',
    'Legenda',
  ];
  return titles[min(level - 1, titles.length - 1)];
}

// ==========================================
// HELPER BARU: TANGGAL, DOMPET, TOMBOL 3D, EFEK VISUAL
// ==========================================

// Tanggal dinormalisasi ke UTC supaya selisih hari tidak kena efek DST.
DateTime dateOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

const int kStreakCoinBonus = 10; // koin bonus saat semua misi utama selesai
int coinsForXp(int xp) => xp ~/ 5; // 5 XP = 1 koin

const List<String> kMonthNames = [
  'Januari',
  'Februari',
  'Maret',
  'April',
  'Mei',
  'Juni',
  'Juli',
  'Agustus',
  'September',
  'Oktober',
  'November',
  'Desember',
];

// Catatan satu hari (dipakai kalender streak & strip mingguan)
class DayLog {
  final int xp;
  final int done;
  final int total;
  final bool mainDone; // semua misi utama selesai
  final bool freeze; // hari ini diselamatkan oleh streak freeze
  const DayLog({
    this.xp = 0,
    this.done = 0,
    this.total = 0,
    this.mainDone = false,
    this.freeze = false,
  });
}

// Warna api streak naik tingkat seiring panjang streak
Color flameColor(int streak) {
  if (streak <= 0) return Colors.grey.shade400;
  if (streak < 3) return Colors.orange.shade300;
  if (streak < 7) return Colors.orange;
  if (streak < 30) return Colors.deepOrange;
  return Colors.red.shade600;
}

// Dompet pemain: koin, streak freeze, dan boost XP.
// Memakai ChangeNotifier agar halaman Toko dan Dashboard selalu sinkron.
class PlayerWallet extends ChangeNotifier {
  static const int freezePrice = 50;
  static const int boostPrice = 80;
  static const int maxFreezes = 2;
  static const int maxBoosts = 3;

  int coins = 0;
  int freezes = 1; // hadiah awal 1 streak freeze
  int boosts = 0; // boost yang disimpan di Tas (belum dipakai)
  bool boostActive = false; // boost XP x2 sampai akhir hari

  bool get canBuyFreeze => coins >= freezePrice && freezes < maxFreezes;
  bool get canBuyBoost => coins >= boostPrice && boosts < maxBoosts;
  bool get canUseBoost => boosts > 0 && !boostActive;
  int get bagItemCount => freezes + boosts;

  bool buyFreeze() {
    if (!canBuyFreeze) return false;
    coins -= freezePrice;
    freezes++;
    notifyListeners();
    return true;
  }

  bool buyBoost() {
    if (!canBuyBoost) return false;
    coins -= boostPrice;
    boosts++;
    notifyListeners();
    return true;
  }

  // Mengambil 1 boost dari Tas dan mengaktifkannya sampai akhir hari
  bool useBoost() {
    if (!canUseBoost) return false;
    boosts--;
    boostActive = true;
    notifyListeners();
    return true;
  }
}

// Tombol bergaya "3D" ala Duolingo: punya bayangan solid yang
// terasa ditekan saat disentuh.
class Duo3DButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color color;

  const Duo3DButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = Colors.deepPurple,
  });

  @override
  State<Duo3DButton> createState() => _Duo3DButtonState();
}

class _Duo3DButtonState extends State<Duo3DButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final face = enabled ? widget.color : Colors.grey.shade400;
    final edge = Color.lerp(face, Colors.black, 0.28)!;
    const depth = 5.0;

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: Padding(
          padding: const EdgeInsets.only(bottom: depth),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 70),
            transform: Matrix4.translationValues(0, _pressed ? depth : 0, 0),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
            decoration: BoxDecoration(
              color: face,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: edge, offset: Offset(0, _pressed ? 0 : depth)),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, color: Colors.white),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- Confetti (tanpa package, digambar dengan CustomPainter) ----------
class _ConfettiPiece {
  final double dx; // kecepatan horizontal
  final double dy; // kecepatan awal vertikal (negatif = naik)
  final double size;
  final double rot;
  final double spin;
  final Color color;
  final bool circle;
  const _ConfettiPiece(
    this.dx,
    this.dy,
    this.size,
    this.rot,
    this.spin,
    this.color,
    this.circle,
  );
}

class ConfettiBurst extends StatefulWidget {
  final VoidCallback onDone;
  const ConfettiBurst({super.key, required this.onDone});

  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<ConfettiBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_ConfettiPiece> _pieces;

  @override
  void initState() {
    super.initState();
    final rand = Random();
    const colors = [
      Colors.deepPurple,
      Colors.amber,
      Colors.orange,
      Colors.pink,
      Colors.lightBlue,
      Colors.green,
    ];
    _pieces = List.generate(
      90,
      (_) => _ConfettiPiece(
        (rand.nextDouble() - 0.5) * 1.3,
        -0.2 - rand.nextDouble() * 0.7,
        6 + rand.nextDouble() * 8,
        rand.nextDouble() * pi * 2,
        (rand.nextDouble() - 0.5) * 14,
        colors[rand.nextInt(colors.length)],
        rand.nextBool(),
      ),
    );
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => CustomPaint(
        size: Size.infinite,
        painter: _ConfettiPainter(_pieces, _c.value),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final List<_ConfettiPiece> pieces;
  final double t;
  _ConfettiPainter(this.pieces, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    const gravity = 1.6;
    final opacity = t < 0.7 ? 1.0 : max(0.0, 1 - (t - 0.7) / 0.3);
    final paint = Paint();
    for (final p in pieces) {
      final x = size.width * 0.5 + p.dx * size.width * t;
      final y = size.height * 0.30 + (p.dy * t + gravity * t * t) * size.height;
      paint.color = p.color.withValues(alpha: opacity);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.rot + p.spin * t);
      if (p.circle) {
        canvas.drawCircle(Offset.zero, p.size / 2, paint);
      } else {
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: p.size,
            height: p.size * 0.5,
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}

void showConfetti(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) =>
        IgnorePointer(child: ConfettiBurst(onDone: () => entry.remove())),
  );
  overlay.insert(entry);
}

// ---------- Teks "+XP" yang melayang naik lalu memudar ----------
class _FloatingText extends StatefulWidget {
  final String text;
  final Color color;
  final VoidCallback onDone;
  const _FloatingText({
    required this.text,
    required this.color,
    required this.onDone,
  });

  @override
  State<_FloatingText> createState() => _FloatingTextState();
}

class _FloatingTextState extends State<_FloatingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = _c.value;
        final opacity = t < 0.7 ? 1.0 : max(0.0, 1 - (t - 0.7) / 0.3);
        final scale = 0.6 + 0.6 * Curves.elasticOut.transform(min(1.0, t * 2));
        return Align(
          alignment: Alignment(0, -0.1 - 0.4 * t),
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: Material(
                type: MaterialType.transparency,
                child: Text(
                  widget.text,
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    color: widget.color,
                    shadows: const [
                      Shadow(color: Colors.white, blurRadius: 8),
                      Shadow(color: Colors.white, blurRadius: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

void showFloatingText(
  BuildContext context,
  String text, {
  Color color = Colors.green,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => IgnorePointer(
      child: _FloatingText(
        text: text,
        color: color,
        onDone: () => entry.remove(),
      ),
    ),
  );
  overlay.insert(entry);
}

// ==========================================
// 1. HALAMAN SETUP AWAL (Nama + Pilih Misi Harian)
// ==========================================
class SetupDailyQuestsPage extends StatefulWidget {
  const SetupDailyQuestsPage({super.key});

  @override
  State<SetupDailyQuestsPage> createState() => _SetupDailyQuestsPageState();
}

class _SetupDailyQuestsPageState extends State<SetupDailyQuestsPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  // Daftar master kebiasaan yang bisa dipilih
  final List<Quest> _availableHabits = [
    Quest(
      title: 'Minum 8 Gelas Air Putih',
      xpReward: 20,
      isMainQuest: true,
      icon: Icons.water_drop,
    ),
    Quest(
      title: 'Membaca Buku 15 Menit',
      xpReward: 30,
      isMainQuest: true,
      icon: Icons.menu_book,
      type: QuestType.reading,
    ),
    Quest(
      title: 'Olahraga / Stretching',
      xpReward: 50,
      isMainQuest: true,
      icon: Icons.fitness_center,
      type: QuestType.exercise,
    ),
    Quest(
      title: 'Belajar Coding 30 Menit',
      xpReward: 40,
      isMainQuest: true,
      icon: Icons.code,
    ),
    Quest(
      title: 'Meditasi / Berdoa',
      xpReward: 25,
      isMainQuest: true,
      icon: Icons.self_improvement,
    ),
  ];

  final Set<String> _selectedIds = {};

  int get _totalPotentialXP => _availableHabits
      .where((h) => _selectedIds.contains(h.id))
      .fold(0, (sum, h) => sum + h.xpReward);

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // Navigasi ke halaman tambah habit, hasilnya dikembalikan lewat pop
  Future<void> _addCustomHabit() async {
    final result = await Navigator.push<Quest>(
      context,
      MaterialPageRoute(builder: (_) => const AddQuestPage(isMainQuest: true)),
    );
    if (result != null) {
      setState(() {
        _availableHabits.add(result);
        _selectedIds.add(result.id); // langsung terpilih
      });
    }
  }

  void _startAdventure() {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih minimal 1 misi dulu ya!')),
      );
      return;
    }

    final dailyQuests = _availableHabits
        .where((h) => _selectedIds.contains(h.id))
        .map((h) => h.copyFresh(main: true))
        .toList();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => GameDashboardPage(
          playerName: _nameController.text.trim(),
          initialQuests: dailyQuests,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Persiapan Berpetualang'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(context).padding.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Form nama karakter dengan validasi
                Form(
                  key: _formKey,
                  child: TextFormField(
                    controller: _nameController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Nama Karaktermu',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final v = value?.trim() ?? '';
                      if (v.isEmpty) return 'Nama tidak boleh kosong';
                      if (v.length < 3) return 'Minimal 3 karakter';
                      if (v.length > 15) return 'Maksimal 15 karakter';
                      return null;
                    },
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Pilih Misi Utamamu Hari Ini!',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Selesaikan misi untuk mendapat XP dan menaikkan Level-mu.',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: _availableHabits.length,
                    itemBuilder: (context, index) {
                      final habit = _availableHabits[index];
                      final isSelected = _selectedIds.contains(habit.id);

                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? scheme.primaryContainer
                              : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? Colors.deepPurple
                                : Colors.grey.shade300,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: CheckboxListTile(
                          secondary: CircleAvatar(
                            backgroundColor: isSelected
                                ? Colors.deepPurple
                                : Colors.grey.shade300,
                            foregroundColor: isSelected
                                ? Colors.white
                                : Colors.black54,
                            child: Icon(habit.icon),
                          ),
                          title: Text(habit.title),
                          subtitle: Text(
                            habit.type == QuestType.general
                                ? 'Hadiah: +${habit.xpReward} XP'
                                : 'Hadiah: +${habit.xpReward} XP • ${habit.type.hint}',
                          ),
                          value: isSelected,
                          activeColor: Colors.deepPurple,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _selectedIds.add(habit.id);
                              } else {
                                _selectedIds.remove(habit.id);
                              }
                            });
                          },
                        ),
                      );
                    },
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _addCustomHabit,
                    icon: const Icon(Icons.add),
                    label: const Text('Tambah Misi Baru'),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${_selectedIds.length} misi dipilih • potensi $_totalPotentialXP XP',
                  style: const TextStyle(
                    color: Colors.deepPurple,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: Duo3DButton(
                    label: 'Mulai Petualangan!',
                    icon: Icons.rocket_launch,
                    onPressed: _selectedIds.isEmpty ? null : _startAdventure,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 2. HALAMAN UTAMA (Dashboard Game / Quest Log)
// ==========================================
enum QuestFilter { semua, belum, selesai }

class GameDashboardPage extends StatefulWidget {
  final String playerName;
  final List<Quest> initialQuests;
  const GameDashboardPage({
    super.key,
    required this.playerName,
    required this.initialQuests,
  });

  @override
  State<GameDashboardPage> createState() => _GameDashboardPageState();
}

class _GameDashboardPageState extends State<GameDashboardPage>
    with WidgetsBindingObserver {
  late List<Quest> _quests;

  // Statistik Player (RPG System)
  int _totalXP = 0;
  int _streakDays = 0;
  int _bestStreakBase = 0; // rekor streak dari hari-hari yang sudah lewat
  bool _streakClaimedToday = false;
  DateTime? _lastStreakDate; // tanggal terakhir streak dihitung
  DateTime? _lastStreakBackup; // untuk membatalkan klaim streak hari ini
  QuestFilter _filter = QuestFilter.semua;

  // Waktu, riwayat, dan dompet (koin + streak freeze + boost)
  int _dayOffset = 0; // dipakai tombol "Simulasi Hari Berikutnya"
  late DateTime _currentDay;
  final Map<String, DayLog> _history = {};
  final PlayerWallet _wallet = PlayerWallet();
  Timer? _clockTimer;

  // Pengaturan & navigasi bawah
  late String _playerName;
  int _tabIndex = 0; // 0 = Beranda, 1 = Toko, 2 = Tas, 3 = Pengaturan
  bool _bonusEnabled = true;
  bool _showXpToast = true;
  bool _feedbackEnabled = true;

  DateTime _now() => DateTime.now().add(Duration(days: _dayOffset));

  LevelInfo get _info => LevelInfo.fromTotal(_totalXP);
  bool get _hasStreakBonus => _bonusEnabled && _streakDays >= 3;
  int get _bestStreak => max(_bestStreakBase, _streakDays);

  List<Quest> get _mainQuests => _quests.where((q) => q.isMainQuest).toList();
  int get _completedCount => _quests.where((q) => q.isCompleted).length;
  double get _dailyProgress =>
      _quests.isEmpty ? 0 : _completedCount / _quests.length;
  int get _remainingMain => _mainQuests.where((q) => !q.isCompleted).length;
  int get _todayXP =>
      _quests.where((q) => q.isCompleted).fold(0, (sum, q) => sum + q.earnedXP);
  DayLog get _todayLog => DayLog(
    xp: _todayXP,
    done: _completedCount,
    total: _quests.length,
    mainDone: _streakClaimedToday,
  );
  Map<String, DayLog> get _historyWithToday => {
    ..._history,
    dateKey(_currentDay): _todayLog,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _quests = widget.initialQuests;
    _playerName = widget.playerName;
    _currentDay = dateOnly(_now());
    _wallet.addListener(_onWalletChanged);
    // Cek pergantian hari tiap menit (selain saat app dibuka kembali)
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      _checkNewDay();
      setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer?.cancel();
    _wallet.removeListener(_onWalletChanged);
    _wallet.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkNewDay();
  }

  void _onWalletChanged() {
    if (mounted) setState(() {});
  }

  List<Quest> _applyFilter(List<Quest> list) {
    switch (_filter) {
      case QuestFilter.belum:
        return list.where((q) => !q.isCompleted).toList();
      case QuestFilter.selesai:
        return list.where((q) => q.isCompleted).toList();
      case QuestFilter.semua:
        return list;
    }
  }

  // Dipanggil saat checkbox ditekan. Quest olahraga & baca buku harus
  // melewati halaman khusus dulu sebelum benar-benar dianggap selesai.
  Future<void> _onQuestChecked(Quest quest, bool done) async {
    if (!done || quest.type == QuestType.general) {
      _toggleQuest(quest, done);
      return;
    }

    final String? result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => quest.type == QuestType.exercise
            ? ExerciseTimerPage(questTitle: quest.title)
            : ReadingNotePage(questTitle: quest.title),
      ),
    );

    // Dibatalkan (tombol kembali) -> quest tetap belum selesai
    if (result == null || !mounted) return;
    _toggleQuest(quest, true, detail: result);
  }

  // Centang / lepas centang quest
  void _toggleQuest(Quest quest, bool done, {String? detail}) {
    final oldLevel = _info.level;
    final wasStreakClaimed = _streakClaimedToday;

    setState(() {
      quest.isCompleted = done;
      quest.detail = done ? detail : null;
      if (done) {
        // Bonus XP 10% jika streak aktif, x2 jika boost aktif
        var multiplier = _hasStreakBonus ? 1.1 : 1.0;
        if (_wallet.boostActive) multiplier *= 2;
        quest.earnedXP = (quest.xpReward * multiplier).round();
        _totalXP += quest.earnedXP;
        _wallet.coins += coinsForXp(quest.earnedXP);
      } else {
        _totalXP = max(0, _totalXP - quest.earnedXP);
        _wallet.coins = max(0, _wallet.coins - coinsForXp(quest.earnedXP));
        quest.earnedXP = 0;
      }
      _updateStreak();
    });

    final newLevel = _info.level;
    final streakJustClaimed = !wasStreakClaimed && _streakClaimedToday;

    if (done) {
      _feedback(heavy: newLevel > oldLevel || streakJustClaimed);
      if (_showXpToast) {
        showFloatingText(
          context,
          '+${quest.earnedXP} XP${_wallet.boostActive ? ' ⚡' : ''}',
          color: _wallet.boostActive
              ? Colors.amber.shade800
              : Colors.green.shade600,
        );
      }
    }
    if (newLevel > oldLevel) {
      showConfetti(context);
      _showLevelUpDialog(newLevel);
    } else if (streakJustClaimed) {
      showConfetti(context);
    }
  }

  // Getar + suara klik saat quest selesai
  void _feedback({bool heavy = false}) {
    if (!_feedbackEnabled) return;
    unawaited(() async {
      try {
        if (heavy) {
          await HapticFeedback.heavyImpact();
        } else {
          await HapticFeedback.mediumImpact();
        }
        await SystemSound.play(SystemSoundType.click);
      } catch (_) {
        // platform tanpa dukungan haptic/suara: abaikan
      }
    }());
  }

  // Streak bertambah saat semua Misi Utama selesai
  void _updateStreak() {
    final main = _mainQuests;
    final allDone = main.isNotEmpty && main.every((q) => q.isCompleted);
    if (allDone && !_streakClaimedToday) {
      _streakClaimedToday = true;
      _lastStreakBackup = _lastStreakDate;
      _lastStreakDate = _currentDay;
      _streakDays++;
      _wallet.coins += kStreakCoinBonus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '🔥 Semua Misi Utama selesai! Streak jadi $_streakDays hari '
                '• +$kStreakCoinBonus koin',
              ),
              backgroundColor: Colors.orange.shade800,
            ),
          );
      });
    } else if (!allDone && _streakClaimedToday) {
      _streakClaimedToday = false;
      _streakDays = max(0, _streakDays - 1);
      _lastStreakDate = _lastStreakBackup;
      _wallet.coins = max(0, _wallet.coins - kStreakCoinBonus);
    }
  }

  // Dipanggil saat app dibuka kembali, tiap menit, dan oleh tombol simulasi.
  // - Menyimpan catatan hari kemarin ke riwayat
  // - Memakai streak freeze (otomatis) kalau ada hari yang terlewat
  // - Memutus streak kalau tidak ada freeze yang cukup
  // - Mereset misi harian
  void _checkNewDay() {
    final today = dateOnly(_now());
    if (!today.isAfter(_currentDay)) return;

    String? message;
    var streakLost = false;
    var lostStreak = 0;

    setState(() {
      _history[dateKey(_currentDay)] = _todayLog;
      _bestStreakBase = max(_bestStreakBase, _streakDays);

      final last = _lastStreakDate;
      if (_streakDays > 0 && last != null) {
        // hari penuh yang terlewat di antara terakhir selesai dan hari ini
        final missed = today.difference(last).inDays - 1;
        if (missed > 0) {
          if (_wallet.freezes >= missed) {
            _wallet.freezes -= missed;
            for (var i = 1; i <= missed; i++) {
              _history[dateKey(last.add(Duration(days: i)))] = const DayLog(
                freeze: true,
              );
            }
            _lastStreakDate = today.subtract(const Duration(days: 1));
            message =
                '🧊 Streak freeze dipakai ($missed hari). '
                'Streak $_streakDays hari tetap aman!';
          } else {
            streakLost = true;
            lostStreak = _streakDays;
            _streakDays = 0;
            _lastStreakDate = null;
          }
        }
      }

      // Reset harian: side quest yang sudah selesai dibuang, sisanya dibersihkan
      _quests.removeWhere((q) => !q.isMainQuest && q.isCompleted);
      for (final q in _quests) {
        q.isCompleted = false;
        q.earnedXP = 0;
        q.detail = null;
      }
      _streakClaimedToday = false;
      _lastStreakBackup = null;
      _wallet.boostActive = false;
      _currentDay = today;
    });

    if (!mounted) return;
    if (streakLost) {
      _showStreakLostDialog(lostStreak);
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              message ?? '☀️ Hari baru dimulai! Misi sudah direset.',
            ),
          ),
        );
    }
  }

  void _simulateNextDay() {
    _dayOffset++;
    _checkNewDay();
  }

  void _showStreakLostDialog(int lost) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💔', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 8),
            Text(
              'Streak $lost hari terputus',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tidak apa-apa! Mulai lagi hari ini dan bangun streak barumu. '
              'Beli Streak Freeze di toko agar streak lebih terlindungi.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Mulai lagi!'),
          ),
        ],
      ),
    );
  }

  void _openCalendar() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StreakCalendarPage(
          history: _historyWithToday,
          today: _currentDay,
          streakDays: _streakDays,
          bestStreak: _bestStreak,
        ),
      ),
    );
  }

  // Toko sekarang berupa tab di navigasi bawah
  void _openShop() => setState(() => _tabIndex = 1);

  void _showLevelUpDialog(int level) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.elasticOut,
              builder: (_, value, child) =>
                  Transform.scale(scale: value, child: child),
              child: const Icon(
                Icons.emoji_events,
                size: 90,
                color: Colors.amber,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'LEVEL UP!',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '$_playerName naik ke Level $level\n(${titleForLevel(level)})',
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Lanjutkan!'),
          ),
        ],
      ),
    );
  }

  // Navigasi ke halaman tambah Side Quest
  Future<void> _openAddSideQuest() async {
    final result = await Navigator.push<Quest>(
      context,
      MaterialPageRoute(builder: (_) => const AddQuestPage(isMainQuest: false)),
    );
    if (result != null) {
      setState(() {
        _quests.add(result);
        // Kalau semua misi utama sudah selesai, streak tidak berubah
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Side quest "${result.title}" ditambahkan')),
      );
    }
  }

  void _openAchievements() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AchievementsPage(
          playerName: _playerName,
          totalXP: _totalXP,
          level: _info.level,
          completedCount: _completedCount,
          streakDays: _streakDays,
          sideQuestDone: _quests
              .where((q) => !q.isMainQuest && q.isCompleted)
              .length,
        ),
      ),
    );
  }

  // Hapus quest dengan geser + opsi Undo
  void _deleteQuest(Quest quest, int index) {
    setState(() {
      _quests.remove(quest);
      if (quest.isCompleted) {
        _totalXP = max(0, _totalXP - quest.earnedXP);
        _wallet.coins = max(0, _wallet.coins - coinsForXp(quest.earnedXP));
      }
      _updateStreak();
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('"${quest.title}" dihapus'),
          action: SnackBarAction(
            label: 'BATAL',
            onPressed: () {
              setState(() {
                _quests.insert(min(index, _quests.length), quest);
                if (quest.isCompleted) {
                  _totalXP += quest.earnedXP;
                  _wallet.coins += coinsForXp(quest.earnedXP);
                }
                _updateStreak();
              });
            },
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final pending = _quests.where((q) => !q.isCompleted).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_tabIndex) {
          0 => '$_playerName • Lv ${info.level}',
          1 => 'Toko',
          2 => 'Tas',
          _ => 'Pengaturan',
        }, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Pencapaian',
            icon: const Icon(Icons.military_tech),
            onPressed: _openAchievements,
          ),
          _appBarChip(
            icon: Icons.local_fire_department,
            color: flameColor(_streakDays),
            text: '$_streakDays',
            tooltip: 'Kalender streak',
            onTap: _openCalendar,
          ),
          _appBarChip(
            icon: Icons.monetization_on,
            color: Colors.amber,
            text: '${_wallet.coins}',
            tooltip: 'Toko',
            onTap: _openShop,
          ),
          const SizedBox(width: 8),
        ],
      ),
      // Empat halaman dalam satu Scaffold, dipilih lewat NavigationBar
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildHome(info),
          ShopView(wallet: _wallet),
          BagView(wallet: _wallet, onGoShop: _openShop),
          _buildSettings(info),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.home_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.home),
            ),
            label: 'Beranda',
          ),
          const NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Toko',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _wallet.bagItemCount > 0,
              label: Text('${_wallet.bagItemCount}'),
              child: const Icon(Icons.backpack_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: _wallet.bagItemCount > 0,
              label: Text('${_wallet.bagItemCount}'),
              child: const Icon(Icons.backpack),
            ),
            label: 'Tas',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Pengaturan',
          ),
        ],
      ),
    );
  }

  // ---------- TAB 1: BERANDA ----------
  Widget _buildHome(LevelInfo info) {
    final mainQuests = _applyFilter(_mainQuests);
    final sideQuests = _applyFilter(
      _quests.where((q) => !q.isMainQuest).toList(),
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            HomeClockCard(
              now: _now,
              playerName: _playerName,
              remainingMain: _remainingMain,
            ),
            const SizedBox(height: 12),
            _buildMascot(),
            const SizedBox(height: 12),
            _buildPlayerCard(info),
            const SizedBox(height: 16),
            _buildFilterChips(),
            const SizedBox(height: 12),

            // Misi Utama
            _sectionTitle('🛡️ Misi Utama Hari Ini'),
            if (mainQuests.isEmpty)
              _emptyText('Tidak ada misi utama pada filter ini.'),
            ...mainQuests.map((q) => _buildQuestTile(q, false)),

            const SizedBox(height: 20),

            // Side Quest
            _sectionTitle('⚡ Side Quest (Tambahan)'),
            if (sideQuests.isEmpty)
              _emptyText(
                'Belum ada side quest. Tambahkan aktivitas spontanmu di sini!',
              ),
            ...sideQuests.map((q) => _buildQuestTile(q, true)),

            const SizedBox(height: 8),
            Duo3DButton(
              label: 'Tambah Side Quest',
              icon: Icons.bolt,
              color: Colors.amber.shade700,
              onPressed: _openAddSideQuest,
            ),
          ],
        ),
      ),
    );
  }

  // ---------- TAB 2: PENGATURAN ----------
  Future<void> _editName() async {
    final controller = TextEditingController(text: _playerName);
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ubah Nama Karakter'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nama',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              final v = value?.trim() ?? '';
              if (v.isEmpty) return 'Nama tidak boleh kosong';
              if (v.length < 3) return 'Minimal 3 karakter';
              if (v.length > 15) return 'Maksimal 15 karakter';
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );

    if (result != null) setState(() => _playerName = result);
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ya'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _resetProgress() async {
    final ok = await _confirm(
      'Reset Progres Hari Ini?',
      'Semua centang hari ini dibatalkan dan XP hari ini ditarik kembali. '
          'Quest tetap ada.',
    );
    if (!ok) return;
    setState(() {
      _totalXP = max(0, _totalXP - _todayXP);
      for (final q in _quests) {
        if (q.isCompleted) {
          _wallet.coins = max(0, _wallet.coins - coinsForXp(q.earnedXP));
        }
        q.isCompleted = false;
        q.earnedXP = 0;
        q.detail = null;
      }
      _updateStreak();
      _tabIndex = 0;
    });
  }

  Future<void> _changeMissions() async {
    final ok = await _confirm(
      'Ganti Misi Harian?',
      'Kamu akan kembali ke halaman persiapan dan progres hari ini akan hilang.',
    );
    if (!ok || !mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const SetupDailyQuestsPage()),
    );
  }

  Widget _settingsHeader(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        color: Colors.deepPurple.shade700,
      ),
    ),
  );

  Widget _buildSettings(LevelInfo info) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: Colors.deepPurple.shade50,
              child: ListTile(
                leading: const CircleAvatar(
                  radius: 24,
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  child: Icon(Icons.person),
                ),
                title: Text(
                  _playerName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  'Lv ${info.level} ${titleForLevel(info.level)} • $_totalXP XP total',
                ),
                trailing: IconButton(
                  tooltip: 'Ubah nama',
                  icon: const Icon(Icons.edit),
                  onPressed: _editName,
                ),
              ),
            ),
            _settingsHeader('Preferensi'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.local_fire_department),
                    title: const Text('Bonus XP Streak'),
                    subtitle: const Text(
                      '+10% XP saat streak 3 hari atau lebih',
                    ),
                    value: _bonusEnabled,
                    onChanged: (v) => setState(() => _bonusEnabled = v),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_active),
                    title: const Text('Animasi +XP'),
                    subtitle: const Text(
                      'Tampilkan XP melayang saat quest selesai',
                    ),
                    value: _showXpToast,
                    onChanged: (v) => setState(() => _showXpToast = v),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.vibration),
                    title: const Text('Getar & Suara Klik'),
                    subtitle: const Text('Umpan balik saat quest selesai'),
                    value: _feedbackEnabled,
                    onChanged: (v) => setState(() => _feedbackEnabled = v),
                  ),
                ],
              ),
            ),
            _settingsHeader('Data'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.swap_horiz),
                    title: const Text('Ganti Misi Harian'),
                    subtitle: const Text('Kembali ke halaman persiapan'),
                    onTap: _changeMissions,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      Icons.restart_alt,
                      color: Colors.red.shade400,
                    ),
                    title: const Text('Reset Progres Hari Ini'),
                    subtitle: const Text(
                      'Batalkan semua centang dan XP hari ini',
                    ),
                    onTap: _resetProgress,
                  ),
                ],
              ),
            ),
            _settingsHeader('Uji Coba'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.skip_next),
                    title: const Text('Simulasi Hari Berikutnya'),
                    subtitle: Text(
                      'Hari ini: ${dateKey(_currentDay)}. Lompat ke besok untuk '
                      'mencoba reset harian, streak, dan streak freeze.',
                    ),
                    onTap: _simulateNextDay,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.monetization_on,
                      color: Colors.amber,
                    ),
                    title: const Text('Tambah 100 Koin'),
                    subtitle: const Text('Untuk mencoba belanja di toko'),
                    onTap: () => setState(() => _wallet.coins += 100),
                  ),
                ],
              ),
            ),
            _settingsHeader('Tentang'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Quest Habit Tracker'),
                subtitle: const Text('Versi 2.0.0'),
                onTap: () => showAboutDialog(
                  context: context,
                  applicationName: 'Quest Habit Tracker',
                  applicationVersion: '2.0.0',
                  applicationIcon: const Icon(
                    Icons.shield,
                    color: Colors.deepPurple,
                  ),
                  children: const [
                    Text('Ubah kebiasaan harianmu menjadi petualangan RPG.'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Card status player dengan progress bar beranimasi + ring harian
  Widget _buildPlayerCard(LevelInfo info) {
    return Card(
      color: Colors.deepPurple.shade50,
      elevation: 2,
      child: Column(
        children: [
          _buildPlayerStats(info),
          const Divider(height: 1),
          _buildWeekStrip(),
          if (_wallet.boostActive)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
              ),
              child: Text(
                '⚡ Boost XP ×2 aktif sampai akhir hari',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.amber.shade900,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlayerStats(LevelInfo info) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          // Ring progres harian
          SizedBox(
            width: 80,
            height: 80,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: _dailyProgress),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOut,
              builder: (_, value, _) => Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 80,
                    height: 80,
                    child: CircularProgressIndicator(
                      value: value,
                      strokeWidth: 8,
                      color: value >= 1 ? Colors.green : Colors.deepPurple,
                      backgroundColor: Colors.deepPurple.shade100,
                    ),
                  ),
                  Text(
                    '${(value * 100).round()}%',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        'Lv ${info.level} ${titleForLevel(info.level)}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Text(
                      '${info.currentXP}/${info.maxXP} XP',
                      style: const TextStyle(color: Colors.deepPurple),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: info.currentXP / info.maxXP),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOut,
                  builder: (_, value, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: value,
                      color: Colors.deepPurple,
                      backgroundColor: Colors.deepPurple.shade100,
                      minHeight: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _hasStreakBonus
                      ? '🔥 Streak $_streakDays hari! Bonus +10% XP aktif.'
                      : 'Capai streak 3 hari untuk bonus XP.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                Text(
                  '$_completedCount dari ${_quests.length} quest selesai',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Chip kecil di AppBar (streak / koin), bisa diketuk
  Widget _appBarChip({
    required IconData icon,
    required Color color,
    required String text,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: color),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: Text(
                  ' $text',
                  key: ValueKey(text),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Maskot kecil yang ekspresinya berubah sesuai progres hari ini
  Widget _buildMascot() {
    final remaining = _remainingMain;
    final lateInDay = _now().hour >= 18;

    String face;
    String message;
    Color tone;
    if (_mainQuests.isNotEmpty && remaining == 0) {
      face = '🥳';
      message = 'Semua misi utama beres! Streak $_streakDays hari aman 🔥';
      tone = Colors.green;
    } else if (_streakDays > 0 && lateInDay) {
      face = '😰';
      message =
          'Streak $_streakDays hari terancam! Tinggal $remaining misi utama lagi.';
      tone = Colors.red;
    } else if (_completedCount == 0) {
      face = '😴';
      message = 'Ayo mulai hari ini! Satu misi kecil dulu saja.';
      tone = Colors.deepPurple;
    } else {
      face = '😎';
      message = 'Bagus! Tinggal $remaining misi utama lagi.';
      tone = Colors.deepPurple;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          transitionBuilder: (child, anim) => ScaleTransition(
            scale: anim.drive(CurveTween(curve: Curves.elasticOut)),
            child: child,
          ),
          child: Container(
            key: ValueKey(face),
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tone.withValues(alpha: 0.12),
              border: Border.all(color: tone.withValues(alpha: 0.4), width: 2),
            ),
            child: Text(face, style: const TextStyle(fontSize: 34)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: tone.withValues(alpha: 0.4), width: 2),
            ),
            child: Text(
              message,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  // Strip Senin-Minggu ala Duolingo: api = hari lengkap, es = freeze
  Widget _buildWeekStrip() {
    const labels = ['S', 'S', 'R', 'K', 'J', 'S', 'M'];
    final monday = _currentDay.subtract(
      Duration(days: _currentDay.weekday - 1),
    );
    final hist = _historyWithToday;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(7, (i) {
          final day = monday.add(Duration(days: i));
          final log = hist[dateKey(day)];
          final isToday = day == _currentDay;
          final isFuture = day.isAfter(_currentDay);

          Color bg = isFuture ? Colors.grey.shade200 : Colors.grey.shade300;
          Widget icon = const SizedBox(width: 16, height: 16);
          if (log?.freeze == true) {
            bg = Colors.lightBlue.shade300;
            icon = const Icon(Icons.ac_unit, size: 16, color: Colors.white);
          } else if (log?.mainDone == true) {
            bg = flameColor(max(_streakDays, 1));
            icon = const Icon(
              Icons.local_fire_department,
              size: 18,
              color: Colors.white,
            );
          } else if ((log?.done ?? 0) > 0) {
            bg = Colors.amber.shade200;
            icon = Icon(Icons.bolt, size: 16, color: Colors.amber.shade900);
          }

          return Column(
            children: [
              Text(
                labels[i],
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                  color: isToday ? Colors.deepPurple : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: bg,
                  border: isToday
                      ? Border.all(color: Colors.deepPurple, width: 2)
                      : null,
                ),
                child: Center(child: icon),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildFilterChips() {
    const labels = {
      QuestFilter.semua: 'Semua',
      QuestFilter.belum: 'Belum',
      QuestFilter.selesai: 'Selesai',
    };
    return Wrap(
      spacing: 8,
      children: QuestFilter.values
          .map(
            (f) => ChoiceChip(
              label: Text(labels[f]!),
              selected: _filter == f,
              selectedColor: Colors.deepPurple.shade200,
              onSelected: (_) => setState(() => _filter = f),
            ),
          )
          .toList(),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
    ),
  );

  Widget _emptyText(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(color: Colors.grey, fontSize: 12)),
  );

  // Tile quest (bisa digeser untuk menghapus)
  Widget _buildQuestTile(Quest quest, bool isSide) {
    final accent = isSide ? Colors.amber.shade800 : Colors.deepPurple;
    final bg = quest.isCompleted
        ? Colors.green.shade50
        : (isSide ? Colors.amber.shade50 : Colors.white);

    return Dismissible(
      key: ValueKey(quest.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => _deleteQuest(quest, max(0, _quests.indexOf(quest))),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: quest.isCompleted ? Colors.green : Colors.grey.shade300,
          ),
        ),
        child: CheckboxListTile(
          secondary: CircleAvatar(
            backgroundColor: quest.isCompleted ? Colors.green : accent,
            foregroundColor: Colors.white,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim.drive(CurveTween(curve: Curves.elasticOut)),
                child: child,
              ),
              child: Icon(
                quest.isCompleted ? Icons.check : quest.icon,
                key: ValueKey(quest.isCompleted),
              ),
            ),
          ),
          title: Text(
            quest.title,
            style: TextStyle(
              decoration: quest.isCompleted
                  ? TextDecoration.lineThrough
                  : TextDecoration.none,
              color: quest.isCompleted ? Colors.grey : null,
            ),
          ),
          isThreeLine: quest.isCompleted && quest.detail != null,
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                quest.isCompleted
                    ? 'Diperoleh: +${quest.earnedXP} XP • +${coinsForXp(quest.earnedXP)} 🪙'
                    : 'Hadiah: +${quest.xpReward} XP • +${coinsForXp(quest.xpReward)} 🪙',
              ),
              if (!quest.isCompleted && quest.type != QuestType.general)
                Row(
                  children: [
                    Icon(quest.type.icon, size: 14, color: accent),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        quest.type.hint,
                        style: TextStyle(fontSize: 12, color: accent),
                      ),
                    ),
                  ],
                ),
              if (quest.isCompleted && quest.detail != null)
                Text(
                  quest.detail!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: Colors.grey.shade700,
                  ),
                ),
            ],
          ),
          value: quest.isCompleted,
          activeColor: Colors.green,
          onChanged: (v) => _onQuestChecked(quest, v ?? false),
        ),
      ),
    );
  }
}

// ==========================================
// 3. HALAMAN TAMBAH QUEST (Form + Validasi)
// ==========================================
class AddQuestPage extends StatefulWidget {
  final bool isMainQuest;
  const AddQuestPage({super.key, required this.isMainQuest});

  @override
  State<AddQuestPage> createState() => _AddQuestPageState();
}

class _AddQuestPageState extends State<AddQuestPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _xpController = TextEditingController();
  IconData _selectedIcon = kQuestIcons.first;
  QuestType _selectedType = QuestType.general;

  @override
  void initState() {
    super.initState();
    _xpController.text = widget.isMainQuest ? '30' : '10';
  }

  @override
  void dispose() {
    _titleController.dispose();
    _xpController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      final quest = Quest(
        title: _titleController.text.trim(),
        xpReward: int.parse(_xpController.text.trim()),
        isMainQuest: widget.isMainQuest,
        icon: _selectedIcon,
        type: _selectedType,
      );
      Navigator.pop(context, quest); // kirim data kembali ke halaman asal
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.isMainQuest ? 'Misi Utama' : 'Side Quest';

    return Scaffold(
      appBar: AppBar(
        title: Text('Tambah $label'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _titleController,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Nama Aktivitas',
                      hintText: 'Misal: Merapikan Meja Kerja',
                      prefixIcon: Icon(Icons.edit),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final v = value?.trim() ?? '';
                      if (v.isEmpty) return 'Nama aktivitas wajib diisi';
                      if (v.length < 3) return 'Minimal 3 karakter';
                      if (v.length > 40) return 'Maksimal 40 karakter';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _xpController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Hadiah XP',
                      prefixIcon: Icon(Icons.star),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final n = int.tryParse(value?.trim() ?? '');
                      if (n == null) return 'Masukkan angka yang valid';
                      if (n < 5 || n > 100) return 'XP harus antara 5 - 100';
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Cara Menyelesaikan',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: QuestType.values
                        .map(
                          (t) => ChoiceChip(
                            avatar: Icon(t.icon, size: 18),
                            label: Text(t.label),
                            selected: _selectedType == t,
                            selectedColor: Colors.deepPurple.shade200,
                            onSelected: (_) =>
                                setState(() => _selectedType = t),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _selectedType.hint,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Pilih Ikon',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: kQuestIcons.map((icon) {
                      final selected = icon == _selectedIcon;
                      return InkWell(
                        borderRadius: BorderRadius.circular(30),
                        onTap: () => setState(() => _selectedIcon = icon),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected
                                ? Colors.deepPurple
                                : Colors.grey.shade200,
                          ),
                          child: Icon(
                            icon,
                            color: selected ? Colors.white : Colors.black54,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Batal'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepPurple,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: _submit,
                          icon: const Icon(Icons.save),
                          label: const Text('Simpan'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 4. HALAMAN TIMER OLAHRAGA (pilih olahraga -> hitung mundur)
// ==========================================
class ExerciseOption {
  final String name;
  final String hint;
  final IconData icon;
  const ExerciseOption(this.name, this.hint, this.icon);
}

// Olahraga rumahan tanpa alat
const List<ExerciseOption> kExercises = [
  ExerciseOption('Plank', 'Tahan posisi papan', Icons.accessibility_new),
  ExerciseOption('Push Up', 'Dada & lengan', Icons.fitness_center),
  ExerciseOption('Sit Up', 'Otot perut', Icons.airline_seat_flat),
  ExerciseOption('Squat', 'Kaki & bokong', Icons.sports_gymnastics),
  ExerciseOption('Jumping Jack', 'Kardio ringan', Icons.directions_run),
  ExerciseOption('Lunges', 'Kaki & keseimbangan', Icons.directions_walk),
  ExerciseOption(
    'Wall Sit',
    'Tahan posisi duduk',
    Icons.airline_seat_legroom_extra,
  ),
  ExerciseOption('Stretching', 'Peregangan', Icons.self_improvement),
];

// Pilihan durasi dalam detik
const List<int> kDurationOptions = [30, 60, 120, 180, 300, 600];

String _formatClock(int totalSeconds) {
  final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final s = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

String _formatDurationLabel(int seconds) {
  if (seconds < 60) return '$seconds detik';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return s == 0 ? '$m menit' : '$m menit $s detik';
}

enum _TimerPhase { setup, running, paused, finished }

class ExerciseTimerPage extends StatefulWidget {
  final String questTitle;
  const ExerciseTimerPage({super.key, required this.questTitle});

  @override
  State<ExerciseTimerPage> createState() => _ExerciseTimerPageState();
}

class _ExerciseTimerPageState extends State<ExerciseTimerPage> {
  ExerciseOption? _selected;
  int _durationSec = 60;
  int _remaining = 60;
  _TimerPhase _phase = _TimerPhase.setup;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTicker() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _remaining--;
        if (_remaining <= 0) {
          _remaining = 0;
          _phase = _TimerPhase.finished;
          t.cancel();
        }
      });
    });
  }

  void _start() {
    setState(() {
      _remaining = _durationSec;
      _phase = _TimerPhase.running;
    });
    _startTicker();
  }

  void _pause() {
    _timer?.cancel();
    setState(() => _phase = _TimerPhase.paused);
  }

  void _resume() {
    setState(() => _phase = _TimerPhase.running);
    _startTicker();
  }

  void _backToSetup() {
    _timer?.cancel();
    setState(() => _phase = _TimerPhase.setup);
  }

  void _claim() {
    Navigator.pop(
      context,
      '💪 ${_selected!.name} • ${_formatDurationLabel(_durationSec)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Timer Olahraga'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _phase == _TimerPhase.setup
                ? _buildSetup()
                : _buildTimerView(),
          ),
        ),
      ),
    );
  }

  // ---- Tahap 1: pilih olahraga & durasi ----
  Widget _buildSetup() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.questTitle,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          'Pilih olahraga, tentukan durasi, lalu mulai timer.',
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 16),
        const Text(
          'Pilih Olahraga',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: kExercises.map((e) {
            final isSel = _selected == e;
            return ChoiceChip(
              avatar: Icon(
                e.icon,
                size: 18,
                color: isSel ? Colors.white : Colors.black54,
              ),
              label: Text(e.name),
              selected: isSel,
              showCheckmark: false,
              selectedColor: Colors.deepPurple,
              labelStyle: TextStyle(color: isSel ? Colors.white : null),
              onSelected: (_) => setState(() => _selected = e),
            );
          }).toList(),
        ),
        if (_selected != null) ...[
          const SizedBox(height: 6),
          Text(
            _selected!.hint,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
        const SizedBox(height: 20),
        const Text('Durasi', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: kDurationOptions.map((d) {
            return ChoiceChip(
              label: Text(_formatDurationLabel(d)),
              selected: _durationSec == d,
              selectedColor: Colors.deepPurple.shade200,
              onSelected: (_) => setState(() {
                _durationSec = d;
                _remaining = d;
              }),
            );
          }).toList(),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _selected == null ? null : _start,
            icon: const Icon(Icons.play_arrow),
            label: Text(
              _selected == null ? 'Pilih olahraga dulu' : 'Mulai Timer',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }

  // ---- Tahap 2: hitung mundur ----
  Widget _buildTimerView() {
    final finished = _phase == _TimerPhase.finished;
    final paused = _phase == _TimerPhase.paused;
    final progress = _durationSec == 0 ? 0.0 : _remaining / _durationSec;

    return Column(
      children: [
        const SizedBox(height: 16),
        Icon(
          finished ? Icons.emoji_events : _selected!.icon,
          size: 48,
          color: finished ? Colors.amber : Colors.deepPurple,
        ),
        const SizedBox(height: 8),
        Text(
          _selected!.name,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        Text(
          'Target ${_formatDurationLabel(_durationSec)}',
          style: const TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: 220,
          height: 220,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 220,
                height: 220,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 12,
                  color: finished ? Colors.green : Colors.deepPurple,
                  backgroundColor: Colors.deepPurple.shade100,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatClock(_remaining),
                    style: const TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    finished ? 'Selesai!' : (paused ? 'Dijeda' : 'Semangat!'),
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        if (finished) ...[
          const Text(
            'Kerja bagus! Olahragamu sudah selesai 🎉',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _claim,
              icon: const Icon(Icons.check),
              label: const Text(
                'Selesaikan Misi',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ),
        ] else
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _backToSetup,
                  icon: const Icon(Icons.close),
                  label: const Text('Batalkan'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: paused ? _resume : _pause,
                  icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                  label: Text(paused ? 'Lanjut' : 'Jeda'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

// ==========================================
// 5. HALAMAN CATATAN BACAAN (ringkasan / pengalaman membaca)
// ==========================================
class ReadingNotePage extends StatefulWidget {
  final String questTitle;
  const ReadingNotePage({super.key, required this.questTitle});

  @override
  State<ReadingNotePage> createState() => _ReadingNotePageState();
}

class _ReadingNotePageState extends State<ReadingNotePage> {
  final _formKey = GlobalKey<FormState>();
  final _bookController = TextEditingController();
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _bookController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final book = _bookController.text.trim();
    final note = _noteController.text.trim();
    Navigator.pop(context, book.isEmpty ? '📖 $note' : '📖 $book: $note');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catatan Bacaan'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.questTitle,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Tulis ringkasan atau pengalaman membacamu untuk menyelesaikan misi ini.',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _bookController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Judul Buku (opsional)',
                      prefixIcon: Icon(Icons.menu_book),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final v = value?.trim() ?? '';
                      if (v.length > 50) return 'Maksimal 50 karakter';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _noteController,
                    textCapitalization: TextCapitalization.sentences,
                    maxLines: 6,
                    maxLength: 300,
                    decoration: const InputDecoration(
                      labelText: 'Ringkasan / Pengalaman Membaca',
                      hintText: 'Misal: Hari ini aku belajar bahwa kebiasaan kecil...',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final v = value?.trim() ?? '';
                      if (v.isEmpty) return 'Catatan wajib diisi';
                      if (v.length < 15) return 'Minimal 15 karakter';
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Batal'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Duo3DButton(
                          label: 'Selesaikan',
                          icon: Icons.check,
                          onPressed: _submit,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 6. HALAMAN PENCAPAIAN (Badge)
// ==========================================
class AchievementBadge {
  final String title;
  final String description;
  final IconData icon;
  final bool unlocked;
  const AchievementBadge(
    this.title,
    this.description,
    this.icon,
    this.unlocked,
  );
}

class AchievementsPage extends StatelessWidget {
  final String playerName;
  final int totalXP;
  final int level;
  final int completedCount;
  final int streakDays;
  final int sideQuestDone;

  const AchievementsPage({
    super.key,
    required this.playerName,
    required this.totalXP,
    required this.level,
    required this.completedCount,
    required this.streakDays,
    required this.sideQuestDone,
  });

  @override
  Widget build(BuildContext context) {
    final badges = <AchievementBadge>[
      AchievementBadge(
        'Langkah Pertama',
        'Selesaikan 1 quest',
        Icons.flag,
        completedCount >= 1,
      ),
      AchievementBadge(
        'Rajin Beraksi',
        'Selesaikan 5 quest',
        Icons.directions_run,
        completedCount >= 5,
      ),
      AchievementBadge(
        'Pemburu XP',
        'Kumpulkan 100 total XP',
        Icons.stars,
        totalXP >= 100,
      ),
      AchievementBadge(
        'Naik Kelas',
        'Capai Level 2',
        Icons.trending_up,
        level >= 2,
      ),
      AchievementBadge(
        'Api Semangat',
        'Raih streak 3 hari',
        Icons.local_fire_department,
        streakDays >= 3,
      ),
      AchievementBadge(
        'Si Spontan',
        'Selesaikan 1 side quest',
        Icons.bolt,
        sideQuestDone >= 1,
      ),
      AchievementBadge(
        'Seminggu Penuh',
        'Raih streak 7 hari',
        Icons.whatshot,
        streakDays >= 7,
      ),
      AchievementBadge(
        'Legenda Api',
        'Raih streak 30 hari',
        Icons.local_fire_department,
        streakDays >= 30,
      ),
      AchievementBadge(
        'Pejuang Sejati',
        'Capai Level 5',
        Icons.shield,
        level >= 5,
      ),
      AchievementBadge(
        'Kolektor XP',
        'Kumpulkan 500 total XP',
        Icons.diamond,
        totalXP >= 500,
      ),
    ];
    final unlockedCount = badges.where((b) => b.unlocked).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pencapaian'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            children: [
              Card(
                margin: const EdgeInsets.all(16),
                color: Colors.deepPurple.shade50,
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    child: Icon(Icons.person),
                  ),
                  title: Text(
                    '$playerName • Lv $level ${titleForLevel(level)}',
                  ),
                  subtitle: Text(
                    'Total XP: $totalXP • Badge: $unlockedCount/${badges.length}',
                  ),
                ),
              ),
              Expanded(
                // GridView responsif: jumlah kolom menyesuaikan lebar layar
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth > 500 ? 3 : 2;
                    return GridView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 1.1,
                      ),
                      itemCount: badges.length,
                      itemBuilder: (context, i) {
                        final b = badges[i];
                        return Card(
                          color: b.unlocked
                              ? Colors.amber.shade50
                              : Colors.grey.shade200,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  b.unlocked ? b.icon : Icons.lock,
                                  size: 40,
                                  color: b.unlocked
                                      ? Colors.amber.shade800
                                      : Colors.grey,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  b.title,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: b.unlocked
                                        ? null
                                        : Colors.grey.shade600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  b.description,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 7. HALAMAN KALENDER STREAK
// ==========================================
class StreakCalendarPage extends StatefulWidget {
  final Map<String, DayLog> history;
  final DateTime today;
  final int streakDays;
  final int bestStreak;

  const StreakCalendarPage({
    super.key,
    required this.history,
    required this.today,
    required this.streakDays,
    required this.bestStreak,
  });

  @override
  State<StreakCalendarPage> createState() => _StreakCalendarPageState();
}

class _StreakCalendarPageState extends State<StreakCalendarPage> {
  late DateTime _month = DateTime.utc(widget.today.year, widget.today.month);

  bool get _isCurrentMonth =>
      _month.year == widget.today.year && _month.month == widget.today.month;

  void _shift(int delta) {
    setState(() => _month = DateTime.utc(_month.year, _month.month + delta));
  }

  Widget _statCard(IconData icon, Color color, String value, String label) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            Text(label, style: TextStyle(color: Colors.grey.shade700)),
          ],
        ),
      ),
    );
  }

  Widget _dayCell(int day) {
    final date = DateTime.utc(_month.year, _month.month, day);
    final log = widget.history[dateKey(date)];
    final isToday = date == widget.today;
    final isFuture = date.isAfter(widget.today);

    Color? bg;
    Widget content = Text(
      '$day',
      style: TextStyle(
        color: isFuture ? Colors.grey.shade400 : Colors.black87,
        fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
      ),
    );
    if (log?.freeze == true) {
      bg = Colors.lightBlue.shade300;
      content = const Icon(Icons.ac_unit, color: Colors.white, size: 18);
    } else if (log?.mainDone == true) {
      bg = Colors.orange;
      content = const Icon(
        Icons.local_fire_department,
        color: Colors.white,
        size: 20,
      );
    } else if ((log?.done ?? 0) > 0) {
      bg = Colors.amber.shade100;
      content = Text(
        '$day',
        style: TextStyle(
          color: Colors.amber.shade900,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(3),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bg,
          border: isToday
              ? Border.all(color: Colors.deepPurple, width: 2)
              : null,
        ),
        child: Center(child: content),
      ),
    );
  }

  Widget _legend(Color color, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 10,
          backgroundColor: color,
          child: Icon(icon, size: 12, color: Colors.white),
        ),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime.utc(_month.year, _month.month + 1, 0).day;
    final leading = _month.weekday - 1; // Senin = 0
    final fullDays = List.generate(daysInMonth, (i) => i + 1)
        .where(
          (d) =>
              widget
                  .history[dateKey(DateTime.utc(_month.year, _month.month, d))]
                  ?.mainDone ==
              true,
        )
        .length;
    const weekdays = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kalender Streak'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: _statCard(
                      Icons.local_fire_department,
                      flameColor(widget.streakDays),
                      '${widget.streakDays}',
                      'Streak saat ini',
                    ),
                  ),
                  Expanded(
                    child: _statCard(
                      Icons.emoji_events,
                      Colors.amber.shade700,
                      '${widget.bestStreak}',
                      'Streak terbaik',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left),
                            onPressed: () => _shift(-1),
                          ),
                          Expanded(
                            child: Text(
                              '${kMonthNames[_month.month - 1]} ${_month.year}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right),
                            onPressed: _isCurrentMonth ? null : () => _shift(1),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: weekdays
                            .map(
                              (w) => Expanded(
                                child: Center(
                                  child: Text(
                                    w,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 4),
                      GridView.count(
                        crossAxisCount: 7,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          for (var i = 0; i < leading; i++)
                            const SizedBox.shrink(),
                          for (var d = 1; d <= daysInMonth; d++) _dayCell(d),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Hari lengkap bulan ini: $fullDays',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _legend(
                    Colors.orange,
                    Icons.local_fire_department,
                    'Semua misi utama',
                  ),
                  _legend(Colors.lightBlue.shade300, Icons.ac_unit, 'Freeze'),
                  _legend(Colors.amber.shade400, Icons.bolt, 'Sebagian'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 8. TOKO & TAS (tab di navigasi bawah)
// ==========================================

// Logo/banner untuk Toko dan Tas. Kalau [awning] true, ada kanopi belang
// di atasnya supaya terlihat seperti etalase toko.
class ShopLogo extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool awning;

  const ShopLogo({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.awning = false,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Color.lerp(color, Colors.black, 0.28)!;
    final light = Color.lerp(color, Colors.white, 0.8)!;

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        children: [
          if (awning)
            Row(
              children: List.generate(
                8,
                (i) => Expanded(
                  child: Container(
                    height: 18,
                    decoration: BoxDecoration(
                      color: i.isEven ? color : light,
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(14),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [color, dark],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.vertical(
                top: awning ? Radius.zero : const Radius.circular(20),
                bottom: const Radius.circular(20),
              ),
              boxShadow: [BoxShadow(color: dark, offset: const Offset(0, 5))],
            ),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                  child: Icon(icon, color: color, size: 32),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- TOKO ----------
class ShopView extends StatelessWidget {
  final PlayerWallet wallet;
  const ShopView({super.key, required this.wallet});

  void _say(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: wallet,
      builder: (context, _) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ShopLogo(
                  icon: Icons.storefront,
                  title: 'TOKO QUEST',
                  subtitle: 'Belanja dengan koin hasil petualanganmu',
                  color: Colors.orange.shade700,
                  awning: true,
                ),
                const SizedBox(height: 8),
                Card(
                  color: Colors.amber.shade50,
                  child: ListTile(
                    leading: const Icon(
                      Icons.monetization_on,
                      color: Colors.amber,
                      size: 36,
                    ),
                    title: Text(
                      '${wallet.coins} Koin',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    subtitle: const Text(
                      'Didapat dari menyelesaikan quest dan menjaga streak',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _ShopItem(
                  icon: Icons.ac_unit,
                  iconColor: Colors.lightBlue,
                  title: 'Streak Freeze',
                  description:
                      'Melindungi streak saat kamu melewatkan satu hari. '
                      'Dipakai otomatis dari Tas.',
                  status:
                      'Di tas: ${wallet.freezes}/${PlayerWallet.maxFreezes}',
                  price: PlayerWallet.freezePrice,
                  soldOut: wallet.freezes >= PlayerWallet.maxFreezes,
                  onBuy: wallet.canBuyFreeze
                      ? () {
                          HapticFeedback.lightImpact();
                          wallet.buyFreeze();
                          _say(context, '🧊 Streak freeze masuk ke Tas!');
                        }
                      : null,
                ),
                _ShopItem(
                  icon: Icons.bolt,
                  iconColor: Colors.amber.shade800,
                  title: 'Boost XP ×2',
                  description:
                      'Disimpan di Tas. Pakai kapan saja: quest setelahnya '
                      'memberi XP dua kali lipat sampai akhir hari.',
                  status:
                      'Di tas: ${wallet.boosts}/${PlayerWallet.maxBoosts}'
                      '${wallet.boostActive ? ' • sedang aktif' : ''}',
                  price: PlayerWallet.boostPrice,
                  soldOut: wallet.boosts >= PlayerWallet.maxBoosts,
                  onBuy: wallet.canBuyBoost
                      ? () {
                          HapticFeedback.lightImpact();
                          wallet.buyBoost();
                          _say(context, '⚡ Boost XP ×2 masuk ke Tas!');
                        }
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ShopItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final String status;
  final int price;
  final bool soldOut;
  final VoidCallback? onBuy;

  const _ShopItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.status,
    required this.price,
    required this.soldOut,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: iconColor.withValues(alpha: 0.15),
              child: Icon(icon, color: iconColor, size: 30),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(description, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(
                    status,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.deepPurple.shade400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 96,
              child: Duo3DButton(
                label: soldOut ? 'Penuh' : '🪙 $price',
                color: Colors.amber.shade700,
                onPressed: onBuy,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- TAS (inventaris) ----------
class _BagItem {
  final String name;
  final IconData icon;
  final Color color;
  final int count;
  final String description;
  final bool usable; // true = bisa dipakai manual dari Tas

  const _BagItem(
    this.name,
    this.icon,
    this.color,
    this.count,
    this.description,
    this.usable,
  );
}

class BagView extends StatelessWidget {
  final PlayerWallet wallet;
  final VoidCallback onGoShop;
  const BagView({super.key, required this.wallet, required this.onGoShop});

  static const int slotCount = 8;

  List<_BagItem> _items() => [
    if (wallet.freezes > 0)
      _BagItem(
        'Streak Freeze',
        Icons.ac_unit,
        Colors.lightBlue,
        wallet.freezes,
        'Melindungi streak saat kamu melewatkan satu hari. '
            'Dipakai otomatis, tidak perlu diaktifkan.',
        false,
      ),
    if (wallet.boosts > 0)
      _BagItem(
        'Boost XP ×2',
        Icons.bolt,
        Colors.amber.shade800,
        wallet.boosts,
        'Pakai kapan saja: semua quest yang kamu selesaikan setelahnya '
            'memberi XP dua kali lipat sampai akhir hari.',
        true,
      ),
  ];

  void _showItem(BuildContext context, _BagItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: item.color.withValues(alpha: 0.15),
              child: Icon(item.icon, color: item.color, size: 36),
            ),
            const SizedBox(height: 12),
            Text(
              item.name,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            Text(
              'Jumlah: ×${item.count}',
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 8),
            Text(item.description, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (item.usable)
              SizedBox(
                width: double.infinity,
                child: Duo3DButton(
                  label: wallet.boostActive
                      ? 'Sedang aktif hari ini'
                      : 'Pakai Sekarang',
                  icon: Icons.bolt,
                  color: Colors.amber.shade700,
                  onPressed: wallet.canUseBoost
                      ? () {
                          wallet.useBoost();
                          HapticFeedback.mediumImpact();
                          Navigator.pop(ctx);
                          showFloatingText(
                            context,
                            '⚡ Boost ×2 aktif!',
                            color: Colors.amber.shade800,
                          );
                        }
                      : null,
                ),
              )
            else
              Text(
                'Barang ini dipakai otomatis.',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: wallet,
      builder: (context, _) {
        final items = _items();
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ShopLogo(
                  icon: Icons.backpack,
                  title: 'TAS PETUALANG',
                  subtitle:
                      '${items.length} jenis barang • ${wallet.bagItemCount} total',
                  color: Colors.teal.shade600,
                ),
                const SizedBox(height: 8),
                if (wallet.boostActive)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '⚡ Boost XP ×2 sedang aktif sampai akhir hari',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.amber.shade900,
                      ),
                    ),
                  ),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.9,
                  children: List.generate(slotCount, (i) {
                    if (i < items.length) {
                      return _BagSlot(
                        item: items[i],
                        onTap: () => _showItem(context, items[i]),
                      );
                    }
                    return _EmptySlot(onTap: onGoShop);
                  }),
                ),
                const SizedBox(height: 16),
                if (items.isEmpty) ...[
                  Text(
                    'Tasmu masih kosong. Belanja di Toko untuk mengisinya!',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 12),
                  Duo3DButton(
                    label: 'Ke Toko',
                    icon: Icons.storefront,
                    color: Colors.orange.shade700,
                    onPressed: onGoShop,
                  ),
                ] else
                  Text(
                    'Ketuk barang untuk melihat detail atau memakainya.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BagSlot extends StatelessWidget {
  final _BagItem item;
  final VoidCallback onTap;
  const _BagSlot({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    return Material(
      color: item.color.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: item.color.withValues(alpha: 0.45), width: 2),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(item.icon, color: item.color, size: 34),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      item.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: item.color,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '×${item.count}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptySlot extends StatelessWidget {
  final VoidCallback onTap;
  const _EmptySlot({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    return Material(
      color: Colors.grey.shade100,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: Colors.grey.shade300, width: 2),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Center(child: Icon(Icons.add, color: Colors.grey.shade400)),
      ),
    );
  }
}

// ==========================================
// 9. KARTU JAM BERANDA
// ==========================================
// Jam digital yang berdetak tiap detik. Hanya kartu ini yang di-rebuild
// (timer-nya sendiri), jadi halaman beranda tidak ikut berat.
class HomeClockCard extends StatefulWidget {
  final DateTime Function() now; // mengikuti "Simulasi Hari Berikutnya"
  final String playerName;
  final int remainingMain; // misi utama yang belum selesai

  const HomeClockCard({
    super.key,
    required this.now,
    required this.playerName,
    required this.remainingMain,
  });

  @override
  State<HomeClockCard> createState() => _HomeClockCardState();
}

class _HomeClockCardState extends State<HomeClockCard> {
  Timer? _timer;

  static const _days = [
    'Senin',
    'Selasa',
    'Rabu',
    'Kamis',
    'Jumat',
    'Sabtu',
    'Minggu',
  ];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  String _greeting(int hour) {
    if (hour >= 4 && hour < 11) return 'Selamat pagi';
    if (hour >= 11 && hour < 15) return 'Selamat siang';
    if (hour >= 15 && hour < 18) return 'Selamat sore';
    return 'Selamat malam';
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.now();
    final endOfDay = DateTime(n.year, n.month, n.day + 1);
    final left = endOfDay.difference(n);
    final urgent = widget.remainingMain > 0 && left.inHours < 3;
    final countdown =
        '${_two(left.inHours)}:${_two(left.inMinutes % 60)}:${_two(left.inSeconds % 60)}';
    final dateText =
        '${_days[n.weekday - 1]}, ${n.day} ${kMonthNames[n.month - 1]} ${n.year}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.deepPurple.shade600, Colors.indigo.shade700],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.deepPurple.shade900,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_greeting(n.hour)}, ${widget.playerName}!',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${_two(n.hour)}:${_two(n.minute)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 44,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                      Text(
                        ':${_two(n.second)}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  dateText,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: urgent
                  ? Colors.red.shade400
                  : Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  urgent ? Icons.warning_amber_rounded : Icons.hourglass_bottom,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(height: 2),
                Text(
                  countdown,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const Text(
                  'sisa hari ini',
                  style: TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

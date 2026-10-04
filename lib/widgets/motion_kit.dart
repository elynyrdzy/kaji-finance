import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/money_format.dart';

/// Kumpulan widget gerak/visual ala Telegram untuk Kaji Finance:
/// segmen geser, counter saldo, avatar gradien, dan empty-state animasi.

/// Segmen pilihan dengan pil penanda yang BERGESER mengikuti pilihan —
/// seperti folder chat Telegram. Label dilokalisasi oleh pemanggil.
class SlidingSegment extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;
  final double height;

  const SlidingSegment({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelect,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        final w = cons.maxWidth / labels.length;
        return Container(
          height: height,
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Stack(
            children: [
              // Reduced motion: pil penanda melompat langsung, tanpa
              // overshoot pegas.
              if (AppMotion.reduced(context))
                Positioned(
                  left: selected * w,
                  top: 2,
                  bottom: 2,
                  width: w,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                )
              else
                AnimatedPositioned(
                  duration: AppMotion.medium,
                  curve: AppMotion.spring,
                  left: selected * w,
                  top: 2,
                  bottom: 2,
                  width: w,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainer,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Row(
                children: List.generate(labels.length, (i) {
                  final active = i == selected;
                  return SizedBox(
                    width: w,
                    height: height,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        if (i != selected) {
                          AppMotion.tap();
                          onSelect(i);
                        }
                      },
                      child: Center(
                        // Responsif: label panjang ("Pengeluaran") menyusut
                        // di layar sempit, bukan overflow.
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              labels[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.labelSm(
                                color: active
                                    ? AppColors.onSurface
                                    : AppColors.onSurfaceVariant,
                              ).copyWith(
                                fontWeight:
                                    active ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Angka saldo yang menghitung naik/turun (count-up) ala aplikasi
/// finansial premium — bukan ganti angka mendadak.
class AnimatedBalance extends StatefulWidget {
  /// Rupiah utuh (int, Phase 4) — diterima sebagai [num] agar pemanggil
  /// double display lama tetap compile; animasi internal tetap double.
  final num value;
  final bool visible;
  final TextStyle? style;
  final String masked;

  /// Bila true, tampil ringkas (`Rp 8,5 jt`) untuk ruang sempit.
  final bool compact;

  const AnimatedBalance({
    super.key,
    required this.value,
    this.visible = true,
    this.style,
    this.masked = '••••••••',
    this.compact = false,
  });

  @override
  State<AnimatedBalance> createState() => _AnimatedBalanceState();
}

class _AnimatedBalanceState extends State<AnimatedBalance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Tween<double> _tween;
  late final CurvedAnimation _curved;

  /// String hasil format terakhir — menghindari re-format dan layout
  /// ulang pada frame-frame ketika angka belum berubah tampilannya.
  String? _lastText;

  @override
  void initState() {
    super.initState();
    // Satu Tween + satu CurvedAnimation dipakai ulang seumur widget —
    // update nilai tak lagi menumpuk listener di controller.
    _tween = Tween(begin: 0, end: widget.value.toDouble());
    _ctrl = AnimationController(duration: AppMotion.slow, vsync: this);
    _curved = CurvedAnimation(parent: _ctrl, curve: AppMotion.pageCurve);
    _ctrl.forward();
  }

  @override
  void didUpdateWidget(AnimatedBalance old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _tween.begin = _tween.evaluate(_curved);
      _tween.end = widget.value.toDouble();
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) {
      return Text(
        widget.masked,
        style: widget.style ?? AppTextStyles.displayCurrencyMobile(),
        overflow: TextOverflow.ellipsis,
      );
    }
    // Reduced motion: tampilkan nilai akhir langsung. Angka keuangan yang
    // menghitung naik selama 380ms membingungkan sekaligus membuang
    // ~23 layout yang tak perlu.
    if (AppMotion.reduced(context)) {
      final finalValue = widget.value.round();
      return Text(
        widget.compact
            ? MoneyFormat.compact(finalValue)
            : MoneyFormat.format(finalValue),
        style: widget.style ?? AppTextStyles.displayCurrencyMobile(),
        overflow: TextOverflow.ellipsis,
      );
    }
    return AnimatedBuilder(
      animation: _curved,
      builder: (_, __) {
        // P4: format integer — bingkai animasi pecahan dibulatkan display.
        // Cache string agar MoneyFormat tidak dipanggil ulang, dan
        // substituent Text yang identik tidak memicu layout ulang.
        final v = _tween.evaluate(_curved).round();
        final text =
            widget.compact ? MoneyFormat.compact(v) : MoneyFormat.format(v);
        final style = widget.style ?? AppTextStyles.displayCurrencyMobile();
        if (text == _lastText) {
          return Text(text, style: style, overflow: TextOverflow.ellipsis);
        }
        _lastText = text;
        return Text(text, style: style, overflow: TextOverflow.ellipsis);
      },
    );
  }
}

/// Avatar dompet ala Telegram: gradien deterministik dari nama +
/// inisial — konsisten di semua layar tanpa aset tambahan.
class WalletAvatar extends StatelessWidget {
  final String name;
  final double radius;

  const WalletAvatar({super.key, required this.name, this.radius = 16});

  static List<Color> gradientFor(String name) {
    var h = 0;
    for (var i = 0; i < name.length; i++) {
      h = (h * 31 + name.codeUnitAt(i)) % 360;
    }
    final hd = h.toDouble();
    return [
      HSLColor.fromAHSL(1, hd, 0.55, 0.45).toColor(),
      HSLColor.fromAHSL(1, (hd + 40) % 360, 0.6, 0.32).toColor(),
    ];
  }

  static String initialsOf(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final p = parts.first;
      return p.characters.take(2).toString().toUpperCase();
    }
    return (parts[0].characters.first + parts[1].characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final g = gradientFor(name);
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: g,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initialsOf(name),
        style: AppTextStyles.labelSm(
          color: Colors.white,
        ).copyWith(fontSize: radius * 0.7, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Ilustrasi empty-state yang "hidup": ikon melayang + denyut lingkaran —
/// pengganti stiker animasi tanpa menambah dependensi/aset.
class EmptyArt extends StatefulWidget {
  final IconData icon;
  final double size;

  const EmptyArt({super.key, required this.icon, this.size = 32});

  @override
  State<EmptyArt> createState() => _EmptyArtState();
}

class _EmptyArtState extends State<EmptyArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: AppMotion.emptyPulse, vsync: this)
      // Loop tak pernah. Reduced motion ditangani di build(); di sini
      // cukup satu kali lalu diam — denyut berulang hanya membakar frame
      // budget untuk dekorasi yang tidak membawa informasi.
      ..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion: gambar statis, tanpa denyut sama sekali.
    if (AppMotion.reduced(context)) {
      return SizedBox(
        width: widget.size * 2.4,
        height: widget.size * 2.4,
        child: Center(
          child: Icon(
            widget.icon,
            size: widget.size,
            color: AppColors.tertiary,
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        // 0..1 sekali, lalu balik ke 0.76 (belum nol) supaya ikon tetap
        // terlihat — tak ada yang berdenyut tanpa henti.
        final t = _ctrl.value * 2 - 1; // -1..1
        final swell = t.abs() * 0.08;
        return SizedBox(
          width: widget.size * 2.4,
          height: widget.size * 2.4,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: widget.size * (1.7 + swell),
                height: widget.size * (1.7 + swell),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.tertiary.withValues(
                    alpha: 0.10 + swell * 0.2,
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(0, t * -3),
                child: Icon(
                  widget.icon,
                  size: widget.size,
                  color: AppColors.tertiary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Kemunculan berjenjang untuk item list (fade + naik 12px).
/// Delay = index × 45ms (maks 360ms). Instan bila reduce-motion aktif.
/// Beri [Key] unik per item agar tidak replay saat list rebuild.
class StaggerEntrance extends StatefulWidget {
  final int index;
  final Widget child;

  const StaggerEntrance({super.key, required this.index, required this.child});

  @override
  State<StaggerEntrance> createState() => _StaggerEntranceState();
}

class _StaggerEntranceState extends State<StaggerEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: AppMotion.medium, vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: AppMotion.sheet);
    // Jeda dihitung terpusat di AppMotion dan DIBATASI: item melewati
    // [AppMotion.staggerCap] tampil instan. Sebelumnya jeda saturates di
    // 360ms sehingga pada list panjang puluhan item menyala bersamaan
    // (masing-masing satu controller + satu Timer).
    final delay = AppMotion.staggerDelay(widget.index);
    if (delay == Duration.zero) {
      _ctrl.value = 1;
    } else {
      Future.delayed(delay, () {
        if (mounted) _ctrl.forward();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return widget.child;
    return FadeTransition(
      opacity: _anim,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.35),
          end: Offset.zero,
        ).animate(_anim),
        child: widget.child,
      ),
    );
  }
}

/// Pengendali goyangan (dipakai indikator PIN saat salah).
class ShakeController extends ChangeNotifier {
  int _n = 0;
  int get count => _n;
  void shake() {
    _n++;
    notifyListeners();
  }
}

/// Pembungkus yang bergoyang horizontal tiap [controller] berdenyut.
/// Tanpa animasi bila reduce-motion aktif.
class Shakeable extends StatefulWidget {
  final ShakeController controller;
  final Widget child;

  const Shakeable({super.key, required this.controller, required this.child});

  @override
  State<Shakeable> createState() => _ShakeableState();
}

class _ShakeableState extends State<Shakeable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;
  int _seen = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: AppMotion.shake, vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.elasticIn);
    _seen = widget.controller.count;
    widget.controller.addListener(_onShake);
  }

  void _onShake() {
    if (widget.controller.count == _seen) return;
    _seen = widget.controller.count;
    if (mounted) _ctrl.forward(from: 0);
  }

  @override
  void didUpdateWidget(Shakeable old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onShake);
      _seen = widget.controller.count;
      widget.controller.addListener(_onShake);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onShake);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return widget.child;
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) {
        final t = math.sin(_anim.value * math.pi * 4) * (1 - _anim.value);
        return Transform.translate(
          offset: Offset(t * 10, 0),
          child: widget.child,
        );
      },
    );
  }
}

/// Fade halus tiap ganti tab BottomNav (state layar tetap terjaga via
/// IndexedStack — hanya lapisan opacity yang dianimasikan).
class TabEntrance extends StatefulWidget {
  final bool active;
  final Widget child;

  const TabEntrance({super.key, required this.active, required this.child});

  @override
  State<TabEntrance> createState() => _TabEntranceState();
}

class _TabEntranceState extends State<TabEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: AppMotion.tab, vsync: this);
    if (widget.active) _ctrl.value = 1;
  }

  @override
  void didUpdateWidget(TabEntrance old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _ctrl.forward(from: 0);
    if (!widget.active) _ctrl.value = 0;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return widget.child;
    return FadeTransition(opacity: _ctrl, child: widget.child);
  }
}

/// Fade-in sekali saat widget pertama tampil (splash halus).
class EntranceFade extends StatefulWidget {
  final Widget child;

  const EntranceFade({super.key, required this.child});

  @override
  State<EntranceFade> createState() => _EntranceFadeState();
}

class _EntranceFadeState extends State<EntranceFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: AppMotion.entrance, vsync: this)
      ..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return widget.child;
    return FadeTransition(opacity: _ctrl, child: widget.child);
  }
}

/// Bilah progres yang nilainya beranimasi (bukan lompat) tiap berubah.
/// Dipakai progres goal tabungan & anggaran.
class AnimatedProgressBar extends StatelessWidget {
  final double value;
  final Color color;
  final Color background;
  final double height;

  const AnimatedProgressBar({
    super.key,
    required this.value,
    required this.color,
    required this.background,
    this.height = 6,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    if (AppMotion.reduced(context)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: v,
          minHeight: height,
          backgroundColor: background,
          valueColor: AlwaysStoppedAnimation(color),
        ),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: v),
      duration: AppMotion.slow,
      curve: Curves.easeOutCubic,
      builder: (_, anim, __) => ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: anim,
          minHeight: height,
          backgroundColor: background,
          valueColor: AlwaysStoppedAnimation(color),
        ),
      ),
    );
  }
}

/// Denting perayaan sekali saat [done] berubah false → true
/// (mis. goal tabungan mencapai 100%). Skala memantul lembut.
class CelebrationPulse extends StatefulWidget {
  final bool done;
  final Widget child;

  const CelebrationPulse({super.key, required this.done, required this.child});

  @override
  State<CelebrationPulse> createState() => _CelebrationPulseState();
}

class _CelebrationPulseState extends State<CelebrationPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: AppMotion.celebrate, vsync: this);
    _anim = Tween(
      begin: 0.94,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
  }

  @override
  void didUpdateWidget(CelebrationPulse old) {
    super.didUpdateWidget(old);
    if (widget.done && !old.done && mounted) _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return widget.child;
    return ScaleTransition(scale: _anim, child: widget.child);
  }
}

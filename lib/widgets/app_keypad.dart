import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/money_format.dart';

/// Keyboard angka bawaan aplikasi ala GoPay — dipakai di semua input
/// numerik (nominal tabungan, PIN) agar keyboard perangkat tidak muncul.
///
/// Tidak ada TextField di dalamnya: pemanggil menyimpan state sendiri
/// (String untuk PIN, int untuk nominal) dan me-render [AppPinDots]
/// atau label nominal hasil format.
class AppKeypad extends StatelessWidget {
  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;

  /// Bila true, tombol '000' diganti '.' untuk input desimal kurs asing.
  /// PIN selalu memakai varian integer (tanpa titik).
  final bool decimal;

  const AppKeypad({
    super.key,
    required this.onKey,
    required this.onBackspace,
    this.decimal = false,
  });

  static const _intKeys = [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '000',
    '0',
    'del',
  ];

  static const _decimalKeys = [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '.',
    '0',
    'del',
  ];

  @override
  Widget build(BuildContext context) {
    final keys = decimal ? _decimalKeys : _intKeys;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1.9,
        children: keys.map((k) {
          return _PopKey(
            onTap: () => k == 'del' ? onBackspace() : onKey(k),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: k == 'del'
                  ? const Icon(
                      Icons.backspace_outlined,
                      size: 18,
                      color: AppColors.outline,
                    )
                  : Text(k, style: AppTextStyles.headlineMd()),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Tombol keypad yang membal (scale 0.9) saat ditekan — umpan balik
/// taktil visual ala GoPay. Instan bila reduce-motion aktif.
class _PopKey extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;

  const _PopKey({required this.onTap, required this.child});

  @override
  State<_PopKey> createState() => _PopKeyState();
}

class _PopKeyState extends State<_PopKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.9 : 1.0,
      duration: AppMotion.durationFor(context, AppMotion.key),
      curve: Curves.easeOut,
      child: InkWell(
        onTap: widget.onTap,
        onTapDown: (_) {
          if (!AppMotion.reduced(context)) setState(() => _pressed = true);
        },
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        borderRadius: BorderRadius.circular(8),
        child: widget.child,
      ),
    );
  }
}

/// Indikator titik-titik PIN (••••••). [filled] = jumlah digit terisi,
/// [length] = total slot (default 6 mengikuti PIN 4–6 digit).
class AppPinDots extends StatelessWidget {
  final int filled;
  final int length;

  const AppPinDots({super.key, required this.filled, this.length = 6});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final on = i < filled;
        return Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: on ? AppColors.tertiary : AppColors.surfaceContainerHigh,
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}

/// Kartu nominal yang jadi SATU-SATUNYA pintu masuk angka di dalam sheet —
/// nominal diubah lewat keypad bawaan, jadi keyboard perangkat tak pernah
/// muncul untuk field ini.
///
/// Keypad sengaja disembunyikan sampai kartu diketuk. Di sheet panjang (tagihan
/// rutin, hutang, bayar cicilan) keypad yang selalu terbuka mendorong
/// kategori/dompet/simpan ke bawah layar sehingga form terasa terkunci — jadi
/// keypad baru muncul saat pengguna benar-benar mengetik, lalu menyingkir
/// lagi lewat tombol "Selesai" atau ketukan kedua pada kartu.
///
/// [amount] adalah nominal dalam **unit mata uang tampil** (mis. 50000);
/// pemanggil menyimpan lewat `MoneyFormat.toBaseMinorUnits`.
///
/// [expanded] dimiliki pemanggil (bukan state internal) supaya keypad juga
/// bisa ditutup dari luar — mis. saat keyboard perangkat mengambil alih
/// sheet, atau sheet ditutup.
class AppAmountPad extends StatefulWidget {
  final String label;
  final int amount;

  /// Kode kurs untuk SELURUH konversi di widget ini: simbol besar, angka
  /// nominal, dan langkah chip cepat. Tidak boleh menggantungkan diri pada
  /// `MoneyFormat.activeCurrency` — pemanggil boleh mengoper kode berbeda
  /// dari kurs aktif aplikasi (mis. editor kurs / nominal impor).
  final String currencyCode;
  final String lang;

  final bool expanded;
  final VoidCallback onToggleExpanded;

  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final ValueChanged<int> onAdjust;
  final VoidCallback onClear;

  /// Chip tambahan opsional (mis. "isi sisa") untuk aksi sekali-tap.
  final String? extraChipLabel;
  final VoidCallback? onExtraChip;

  const AppAmountPad({
    super.key,
    required this.label,
    required this.amount,
    required this.currencyCode,
    required this.lang,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onKey,
    required this.onBackspace,
    required this.onAdjust,
    required this.onClear,
    this.extraChipLabel,
    this.onExtraChip,
  });

  /// Langkah tambah cepat mengikuti denomination kurs (10 rb / 50 rb /
  /// 100 rb untuk IDR, bukan angka yang tak berarti di kurs asing).
  static List<int> stepsFor(String curCode) => curCode == 'IDR'
      ? const [10000, 50000, 100000]
      : curCode == 'JPY'
          ? const [100, 500, 1000]
          : const [5, 20, 50];

  @override
  State<AppAmountPad> createState() => _AppAmountPadState();
}

class _AppAmountPadState extends State<AppAmountPad>
    with SingleTickerProviderStateMixin {
  final _cardKey = GlobalKey();

  /// Umpan balik tekan/hover untuk SELURUH kartu, bukan hanya ikon edit.
  /// Kartu adalah target ketuk sebesar layar, jadi umpan balik tekannya
  /// harus terasa di kartu itu sendiri.
  bool _pressed = false;
  bool _hovered = false;

  /// Denyut angka setelah chip tambah cepat dipakai: chip boleh membiarkan
  /// keypad tertutup, jadi angka yang melompat adalah satu-satunya penanda
  /// bahwa nilai baru masuk. Sekali jalan, tak berulang.
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(duration: AppMotion.medium, vsync: this);
  }

  @override
  void didUpdateWidget(AppAmountPad old) {
    super.didUpdateWidget(old);
    if (widget.expanded && !old.expanded) _revealCard();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _setPressed(bool v) {
    if (_pressed == v || AppMotion.reduced(context)) return;
    setState(() => _pressed = v);
  }

  void _setHovered(bool v) {
    if (_hovered == v || AppMotion.reduced(context)) return;
    setState(() => _hovered = v);
  }

  /// Bawa kartu ke area atas sheet begitu keypad terbuka — di sheet hutang
  /// pad-nya jauh dari atas, tanpa ini keypad bisa muncul di bawah lipatan
  /// dan kontrol simpan makin jauh dari jangkauan.
  void _revealCard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _cardKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.2,
        duration: AppMotion.durationFor(context, AppMotion.medium),
        curve: AppMotion.sheet,
      );
    });
  }

  void _toggle() {
    AppMotion.tap();
    widget.onToggleExpanded();
  }

  /// Chip tambah cepat boleh membiarkan keypad tertutup, jadi angka yang
  /// berdenyut adalah penara nilai barunya.
  void _bump() {
    if (!AppMotion.reduced(context)) _pulse.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final symbol = MoneyFormat.symbolOf(widget.currencyCode);
    final lang = widget.lang;
    final open = widget.expanded;
    final active = _pressed || _hovered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedScale(
          scale: active ? 0.985 : 1.0,
          duration: AppMotion.durationFor(context, AppMotion.key),
          curve: Curves.easeOut,
          child: InkWell(
            key: _cardKey,
            onTap: _toggle,
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            onHover: _setHovered,
            borderRadius: BorderRadius.circular(16),
            child: AnimatedContainer(
              duration: AppMotion.durationFor(context, AppMotion.fast),
              curve: AppMotion.sheet,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16),
                // Keypad terbuka → tepi hijau tipis: penanda fokus sedang
                // ada di kartu ini. Tekan/hover cukup garis netral supaya
                // tak salah dibaca sebagai keadaan "sedang mengetik".
                border: Border.all(
                  color: open
                      ? AppColors.tertiary.withValues(alpha: 0.55)
                      : active
                          ? AppColors.outline.withValues(alpha: 0.45)
                          : Colors.transparent,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const _PadDot(),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          widget.label.toUpperCase(),
                          style: AppTextStyles.labelCaps(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (_, child) {
                      // Denyut setengah sinus: kembali tepat ke 1.0 di detik 0
                      // maupun detik 1, jadi angka hanya bergerak sesaat setelah
                      // chip dipakai lalu diam lagi. Transform (bukan ukuran)
                      // → chip di bawahnya tak pernah bergeser.
                      final bump = math.sin(_pulse.value * math.pi);
                      return Transform.scale(
                        scale: 1 + 0.07 * bump,
                        alignment: Alignment.center,
                        child: child,
                      );
                    },
                    child: FittedBox(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            symbol,
                            style: AppTextStyles.tabularAmountLg(
                              color: AppColors.outline,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            // `currency:` wajib di KEDUA call: tanpa itu angka
                            // diskalakan kurs aktif tapi simbol diambil dari
                            // [currencyCode] → tampil dobel simbol dan angka
                            // salah kalau pemanggil lewat dari kurs aktif.
                            MoneyFormat.format(
                              MoneyFormat.toBaseMinorUnits(
                                widget.amount,
                                currency: widget.currencyCode,
                              ),
                            ).replaceFirst('$symbol ', ''),
                            style: AppTextStyles.displayCurrencyMobile(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Baris bawah ikut menyusut saat "Selesai" menggantikan
                  // petunjuk: kartu terasa membuka, bukan melompat.
                  AnimatedSize(
                    duration: AppMotion.durationFor(context, AppMotion.fast),
                    curve: AppMotion.sheet,
                    alignment: Alignment.center,
                    child: open
                        ? _DonePill(
                            label: AppStrings.get('keypadDone', lang),
                            onTap: _toggle,
                          )
                        : _TapHint(
                            text: AppStrings.get('amountTapToEdit', lang),
                          ),
                  ),
                  const SizedBox(height: 10),
                  // Wrap (bukan Row): 4–5 chip tak overflow di layar 320px.
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 2,
                    runSpacing: 6,
                    children: [
                      for (final s in AppAmountPad.stepsFor(
                        widget.currencyCode,
                      ))
                        _padChip(
                          '+${MoneyFormat.compact(MoneyFormat.toBaseMinorUnits(s, currency: widget.currencyCode))}',
                          () {
                            widget.onAdjust(s);
                            _bump();
                          },
                        ),
                      if (widget.onExtraChip != null &&
                          widget.extraChipLabel != null)
                        _padChip(widget.extraChipLabel!, () {
                          widget.onExtraChip!();
                          _bump();
                        }),
                      _padChip(AppStrings.get('clear', lang), () {
                        widget.onClear();
                        _bump();
                      }, isDanger: true),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        // Keypad tumbuh di bawah kartu (bukan menimpa), jadi isi sheet
        // tetap urut dan pengguna bisa menggulir ke kontrol berikutnya.
        AnimatedSize(
          duration: AppMotion.durationFor(context, AppMotion.medium),
          curve: AppMotion.sheet,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: AppKeypad(
                    onKey: widget.onKey,
                    onBackspace: widget.onBackspace,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// Petunjuk "kartu ini bisa diketuk". Tanpa baris ini kartu nominal hanya
/// terbaca sebagai teks, padahal itu satu-satunya jalan mengubah angka —
/// keyboard perangkat sengaja tidak ada untuk field ini.
class _TapHint extends StatelessWidget {
  final String text;

  const _TapHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.edit_outlined, size: 13, color: AppColors.tertiary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySm(color: AppColors.tertiary),
          ),
        ),
      ],
    );
  }
}

/// Tombol "Selesai" — jalan pintas menutup keypad supaya pengguna bisa naik
/// ke kategori/dompet/simpan tanpa harus menggulir melewati keypad.
class _DonePill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _DonePill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.tertiary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppColors.tertiary.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_rounded,
                size: 14,
                color: AppColors.tertiary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppTextStyles.labelSm(color: AppColors.tertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Titik status kecil di depan label nominal — penanda "kartu ini aktif",
/// mengikuti kartu nominal Tambah Transaksi.
class _PadDot extends StatelessWidget {
  const _PadDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(
        color: AppColors.tertiary,
        shape: BoxShape.circle,
      ),
    );
  }
}

Widget _padChip(String label, VoidCallback onTap, {bool isDanger = false}) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isDanger
              ? AppColors.surfaceContainerHigh
              : AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: isDanger
              ? AppTextStyles.bodySm(color: AppColors.error)
              : AppTextStyles.tabularAmount(),
        ),
      ),
    ),
  );
}

/// Input nominal lengkap (tampilan terformat + keypad) dengan state
/// internal. [initialRaw]/[onChanged] memakai unit mata uang tampil
/// (mis. 50000 atau 10.50); pemanggil mengonversi ke basis IDR via
/// `MoneyFormat.toBase` saat simpan — sama seperti AddTransactionScreen.
class AppAmountInput extends StatefulWidget {
  final double initialRaw;
  final ValueChanged<double> onChanged;

  /// Override tampilan nominal (default format kurs aktif). Editor kurs
  /// memakai angka mentah agar tak misleading berlabel "Rp".
  final String Function(double value)? displayFormat;

  const AppAmountInput({
    super.key,
    required this.initialRaw,
    required this.onChanged,
    this.displayFormat,
  });

  @override
  State<AppAmountInput> createState() => _AppAmountInputState();
}

class _AppAmountInputState extends State<AppAmountInput> {
  late String _raw;

  static String _initialText(double v) {
    if (!v.isFinite || v <= 0) return '';
    if (v == v.roundToDouble()) return v.toInt().toString();
    var s = v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
    return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  }

  /// IDR/JPY tak bersubunit: titik diperlakukan sebagai pemisah ribuan
  /// (samakan semantik parse lama — "10.000" → 10000), bukan desimal.
  bool get _groupedThousands =>
      MoneyFormat.activeCurrency == 'IDR' ||
      MoneyFormat.activeCurrency == 'JPY';

  double get _value {
    if (_raw.isEmpty || _raw == '.') return 0;
    return double.tryParse(_raw) ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _raw = _initialText(widget.initialRaw);
  }

  void _update(String next) {
    setState(() => _raw = next);
    widget.onChanged(_value);
  }

  void _press(String k) {
    if (k == '.') {
      if (_groupedThousands) {
        if (_raw.isEmpty) return;
        final next = '${_raw}000';
        if (next.length <= 14) _update(next);
      } else {
        if (_raw.contains('.')) return;
        _update(_raw.isEmpty ? '0.' : '$_raw.');
      }
      return;
    }
    final digits = k.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return;
    if (_raw.contains('.')) {
      final room = 2 - _raw.split('.').last.length;
      if (room <= 0) return;
      _update('$_raw${digits.substring(0, room.clamp(0, digits.length))}');
      return;
    }
    var next = (_raw.isEmpty || _raw == '0') ? digits : '$_raw$digits';
    next = next.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    if (next.length <= 11) _update(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              widget.displayFormat?.call(_value) ??
                  MoneyFormat.format(MoneyFormat.toBaseMinorUnits(_value)),
              style: AppTextStyles.displayCurrencyMobile(),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 8),
        AppKeypad(
          decimal: true,
          onKey: _press,
          onBackspace: () {
            if (_raw.isEmpty) return;
            _update(_raw.substring(0, _raw.length - 1));
          },
        ),
      ],
    );
  }
}

/// Bottom sheet input nominal bawaan aplikasi (menggantikan AlertDialog +
/// TextField angka agar keyboard perangkat tidak muncul).
///
/// Return nominal mentah (unit mata uang tampil, bisa desimal) atau null
/// bila batal. Sheet ini tidak mengonversi kurs; pemanggil memakai
/// `MoneyFormat.toBase` bila nilai simpan basis IDR.
Future<double?> showAppAmountSheet(
  BuildContext context, {
  required String title,
  String? message,
  required String cancelLabel,
  required String okLabel,
  double initialRaw = 0,
  String Function(double value)? displayFormat,
}) {
  var raw = initialRaw;
  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceContainer,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: AppTextStyles.headlineSm()),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message,
                style: AppTextStyles.bodySm(),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 12),
            AppAmountInput(
              initialRaw: initialRaw,
              onChanged: (v) => raw = v,
              displayFormat: displayFormat,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(sheetCtx),
                    child: Text(cancelLabel),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.tertiary,
                    ),
                    onPressed: () => Navigator.pop(sheetCtx, raw),
                    child: Text(
                      okLabel,
                      style: AppTextStyles.labelSm(color: AppColors.onTertiary),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

///
/// Return PIN yang dimasukkan, atau null bila pengguna membatalkan.
/// Tombol OK aktif setelah [minLength] digit (default 4, maks 6).
Future<String?> showAppPinSheet(
  BuildContext context, {
  required String title,
  String? message,
  required String cancelLabel,
  required String okLabel,
  int minLength = 4,
  int maxLength = 6,
}) {
  var pin = '';
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceContainer,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => StatefulBuilder(
      builder: (ctx2, setSB) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: AppTextStyles.headlineSm()),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(
                  message,
                  style: AppTextStyles.bodySm(),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              AppPinDots(filled: pin.length),
              const SizedBox(height: 16),
              AppKeypad(
                // Tombol '000' keypad: untuk PIN hanya 1 digit per ketuk.
                onKey: (k) => setSB(() {
                  final digits = k.replaceAll(RegExp(r'[^0-9]'), '');
                  if (digits.isEmpty) return;
                  final one = digits[digits.length - 1];
                  if ((pin + one).length <= maxLength) pin += one;
                }),
                onBackspace: () => setSB(() {
                  if (pin.isNotEmpty) {
                    pin = pin.substring(0, pin.length - 1);
                  }
                }),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(sheetCtx),
                      child: Text(cancelLabel),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.tertiary,
                      ),
                      onPressed: pin.length >= minLength
                          ? () => Navigator.pop(sheetCtx, pin)
                          : null,
                      child: Text(
                        okLabel,
                        style: AppTextStyles.labelSm(
                          color: AppColors.onTertiary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

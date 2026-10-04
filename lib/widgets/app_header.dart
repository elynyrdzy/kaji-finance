import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../models/profile_model.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/profile_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/app_nav.dart';
import '../utils/money_format.dart';
import '../utils/profile_switch.dart';
import 'motion_kit.dart';

/// Bentuk sheet yang dipakai header (notifikasi + profil). Disatukan di
/// sini supaya dua panel dari header ini terbaca sebagai satu keluarga,
/// bukan dua dialog yang kebetulan sama.
const RoundedRectangleBorder _sheetShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
);

/// Profil yang sedang aktif di [list], atau null bila id aktif tidak ada
/// di dalamnya.
///
/// Sengaja TANPA fallback ke profil pertama (berbeda dari avatar yang
/// digambar di header): untuk mendeteksi "snapshot basi" justru perlu
/// null sebagai jawaban — "profil aktifku tak ada di data yang kupunya".
ProfileModel? _activeIn(List<ProfileModel> list) {
  for (final pr in list) {
    if (pr.id == ProfileService.activeId) return pr;
  }
  return null;
}

/// Inisial untuk avatar: satu huruf, `?` bila nama kosong.
String _initialOf(String name) {
  final clean = name.trim();
  return clean.isEmpty ? '?' : clean[0].toUpperCase();
}

/// Header aplikasi: logo, judul layar, lonceng notifikasi, menu profil.
///
/// Menu profil sengaja dua langkah (menu aksi → daftar akun), bukan
/// langsung membuka daftar. Sebagian besar pengguna cuma punya SATU
/// profil, jadi menu yang langsung memuntahkan daftar profil membuat dua
/// aksi yang paling sering dipakai — ganti nama akun dan buka pengaturan —
/// tenggelam di antara baris yang tak berguna. Dua langkah juga memberi
/// "Ubah Akun" satu arti yang tak ambigu: mengganti profil aktif.
class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  final String title;

  const AppHeader({super.key, required this.title});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  void _showNotifications(BuildContext context) {
    final fp = context.read<FinanceProvider>();
    final lang = context.read<AppSettingsProvider>().languageCode;
    final over = fp.budgets.where((b) => b.status.name != 'onTrack').toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: _sheetShape,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.notifications_outlined,
                    color: AppColors.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    AppStrings.get('notifications', lang),
                    style: AppTextStyles.headlineSm(),
                  ),
                  const Spacer(),
                  if (over.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.errorContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        AppStrings.fill('alertCount', lang, {'n': over.length}),
                        style: AppTextStyles.labelCaps(
                          color: AppColors.onErrorContainer,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (fp.transactions.isEmpty && fp.budgets.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.inbox_outlined,
                        color: AppColors.outline,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppStrings.get('noActivity', lang),
                          style: AppTextStyles.bodySm(),
                        ),
                      ),
                    ],
                  ),
                ),
              if (over.isNotEmpty)
                ...over.map(
                  (b) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.errorContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            b.icon,
                            color: AppColors.onErrorContainer,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppStrings.fill('budgetExceeded', lang, {
                                  'name': b.name,
                                  'pct':
                                      '${(b.percent * 100).toStringAsFixed(0)}%',
                                }),
                                style: AppTextStyles.bodyMd().copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${MoneyFormat.format(b.spent)} / ${MoneyFormat.format(b.limit)}',
                                style: AppTextStyles.bodySm(),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (fp.transactions.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.receipt_long,
                        color: AppColors.tertiary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppStrings.fill('headerTxStored', lang, {
                            'n': fp.transactions.length,
                            'balance': MoneyFormat.format(fp.balance),
                          }),
                          style: AppTextStyles.bodySm(),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface.withValues(alpha: 0.9),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.savings,
                  size: 18,
                  color: AppColors.onPrimaryFixed,
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('KAJI FINANCE', style: AppTextStyles.labelCaps()),
                  Text(title, style: AppTextStyles.headlineSm()),
                ],
              ),
              const Spacer(),
              Consumer<FinanceProvider>(
                builder: (_, fp, __) {
                  final hasAlert = fp.budgets.any(
                    (b) => b.status.name != 'onTrack',
                  );
                  return Stack(
                    children: [
                      IconButton(
                        onPressed: () => _showNotifications(context),
                        icon: const Icon(
                          Icons.notifications_outlined,
                          size: 20,
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                      if (hasAlert)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppColors.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(width: 4),
              const _ProfileMenuButton(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tombol avatar di header sekaligus satu-satunya gerbang sheet menu
/// profil.
///
/// State-nya hidup di widget kecil ini, bukan di [AppHeader], supaya
/// header tetap StatelessWidget dan hanya satu tempat yang memutuskan
/// kapan registry profil perlu dibaca ulang.
class _ProfileMenuButton extends StatefulWidget {
  const _ProfileMenuButton();

  @override
  State<_ProfileMenuButton> createState() => _ProfileMenuButtonState();
}

class _ProfileMenuButtonState extends State<_ProfileMenuButton> {
  /// Registry profil hasil baca terakhir — HANYA untuk menggambar avatar
  /// (satu inisial + satu warna). Daftar akun di sheet tidak pernah memakai
  /// snapshot ini: setiap ketukan avatar membaca registry lagi, jadi
  /// profil yang dibuat atau dihapus di Pengaturan tak mungkin tampil basi.
  List<ProfileModel> _snapshot = const [];

  /// Penjaga baca ganda: avatar bisa dibangun ulang berkali-kali (mis.
  /// tiap mutasi keuangan) dan satu baca yang sedang berjalan tak perlu
  /// digandakan.
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_readRegistry());
  }

  Future<void> _readRegistry() async {
    if (_reading) return;
    _reading = true;
    final list = await ProfileService.profiles();
    _reading = false;
    if (!mounted) return;
    // Hasil identik tak memicu setState. Itu yang menjaga build yang
    // memanggil [_readRegistry] dari berputar: snapshot tetap sama,
    // build berikutnya tak melihat apa pun yang perlu diperbarui.
    if (_sameRegistry(_snapshot, list)) return;
    setState(() => _snapshot = list);
  }

  /// Avatar hanya menampilkan profil AKTIF, jadi satu-satunya tanda
  /// "snapshot basi" yang bisa dilihat tanpa await adalah id aktif yang
  /// hilang dari snapshot — mis. profil aktif dihapus atau diganti dari
  /// Pengaturan.
  ///
  /// Snapshot kosong BUKAN bukti basi: itu juga kondisi "registry belum
  /// terbaca", dan membacanya lagi setiap build akan berputar tanpa henti.
  bool get _snapshotStale =>
      _snapshot.isNotEmpty && _activeIn(_snapshot) == null;

  bool _sameRegistry(List<ProfileModel> a, List<ProfileModel> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].name != b[i].name ||
          a[i].color != b[i].color) {
        return false;
      }
    }
    return true;
  }

  /// Buka sheet menu profil.
  ///
  /// Semua yang perlu dibaca dari provider — bahasa, nama akun, ringkas
  /// data — diambil SEBELUM await pertama (aturan use_build_context_safely).
  /// Setelah sheet ditutup, `context` yang dirujuk closure di bawah bukan
  /// milik sheet lagi: dia kembali jadi context layar, yang memang masih
  /// hidup selama header ini tampil.
  Future<void> _openMenu() async {
    final fp = context.read<FinanceProvider>();
    final lang = context.read<AppSettingsProvider>().languageCode;
    final messenger = ScaffoldMessenger.of(context);

    // Registry dibaca DI SINI, bukan di dalam sheet. Sheet begitu tak
    // pernah memakai FutureBuilder kosong: tak ada kedipan "tak ada akun",
    // dan daftarnya persis dengan isi disk saat ini — termasuk profil yang
    // baru dibuat di Pengaturan.
    final profiles = await ProfileService.profiles();
    if (!mounted) return;
    if (!_sameRegistry(_snapshot, profiles)) {
      setState(() => _snapshot = profiles);
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: _sheetShape,
      builder: (_) => _ProfileSheet(
        lang: lang,
        // Konteks header, dipakai setelah sheet ditutup.
        outer: context,
        profiles: profiles,
        accountName: fp.accountName,
        wallets: fp.wallets.length,
        transactions: fp.transactions.length,
        onRename: () => showDialog<void>(
          context: context,
          builder: (_) => _RenameAccountDialog(
            lang: lang,
            initialName: fp.accountName,
            fp: fp,
            messenger: messenger,
          ),
        ),
        onOpenSettings: () {
          // Pindah ke tab Pengaturan (index 4). Fallback snackbar bila
          // dipanggil di luar RootShell.
          if (AppNav.goToTab != null) {
            AppNav.goToTab!(4);
          } else {
            messenger.showSnackBar(
              SnackBar(content: Text(AppStrings.get('openSettingsHint', lang))),
            );
          }
        },
      ),
    );

    // Sheet ditutup: aksi di dalamnya mungkin baru saja mengganti
    // profil (pop dulu, lalu orchestrator switch + PIN). Baca lagi supaya
    // avatar langsung ikut — termasuk saat step-up PIN melambat.
    await _readRegistry();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild saat provider keuangan berubah: perpindahan profil selalu
    // memuat ulang state dari ruang profil tujuan, jadi ini sinyal gratis
    // bahwa id aktif mungkin sudah berganti tanpa perlu invalidate manual
    // dari Pengaturan.
    context.watch<FinanceProvider>();
    if (_snapshotStale) unawaited(_readRegistry());
    final profile =
        _activeIn(_snapshot) ?? (_snapshot.isEmpty ? null : _snapshot.first);
    return InkWell(
      onTap: _openMenu,
      borderRadius: BorderRadius.circular(16),
      child: _ProfileAvatar(
        profile: profile,
        radius: 16,
        textStyle: AppTextStyles.bodyMd(),
      ),
    );
  }
}

/// Sheet profil dua langkah: menu aksi (bawaan) → daftar akun.
///
/// Presentation-nya sheet yang sama BERTUKAR ISI DI TEMPAT, bukan sheet
/// kedua atau route baru. Alasannya: sheet kedua menumpuk dua barrier di
/// layar phone yang sempit — sheet menu di bawahnya tertutup penuh
/// sehingga konteks "dari mana saya datang" hilang, dan barrier yang atas
/// membuat sheet yang bawah mustahil dijangkau. Route baru sebaliknya
/// membuang sheet yang masih terbuka, jadi pengguna harus menekan back
/// hanya untuk melihat daftar. Tukar-di-tempat memakai satu gestur yang
/// sudah dipahami pengguna (chevron-back / tombol back) plus satu morph
/// tinggi yang menjelaskan hierarki: menu → daftar.
class _ProfileSheet extends StatefulWidget {
  final String lang;

  /// Konteks di LUAR sheet. Diperlukan karena perpindahan profil
  /// dijalankan SETELAH sheet ditutup (lihat [_ProfileList]).
  final BuildContext outer;

  final List<ProfileModel> profiles;
  final String accountName;
  final int wallets;
  final int transactions;

  final VoidCallback onRename;
  final VoidCallback onOpenSettings;

  const _ProfileSheet({
    required this.lang,
    required this.outer,
    required this.profiles,
    required this.accountName,
    required this.wallets,
    required this.transactions,
    required this.onRename,
    required this.onOpenSettings,
  });

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  /// true = langkah "Ubah Akun" (daftar profil), false = menu aksi.
  bool _listing = false;

  /// Hanya satu profil berarti tak ada tujuan untuk bertukar; registry
  /// kosong (baca gagal) ikut dihitung karena satu-satunya jalan yang
  /// tersisa memang menambah profil di Pengaturan.
  bool get _onlyOne => widget.profiles.length <= 1;

  void _toList() => setState(() => _listing = true);

  void _toMenu() => setState(() => _listing = false);

  /// Tutup sheet dulu, baru jalankan aksi. Dialog dan snackbar harus
  /// muncul DI ATAS sheet yang sudah menutup — kalau urutannya dibalik,
  /// dialognya terbuka di balik sheet dan tak kelihatan.
  void _closeThen(VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  /// Kepala langkah daftar: tombol kembali + judul. Identitas (avatar,
  /// nama akun, jumlah dompet) sengaja hanya di langkah menu — di daftar
  /// yang dibutuhkan adalah "ke mana saya kembali", bukan siapa saya.
  Widget _listHeader() {
    final lang = widget.lang;
    return Row(
      children: [
        IconButton(
          onPressed: _toMenu,
          icon: const Icon(
            Icons.arrow_back,
            size: 20,
            color: AppColors.onSurfaceVariant,
          ),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.get('changeAccount', lang),
                style: AppTextStyles.headlineMd(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                AppStrings.get('changeAccountDesc', lang),
                style: AppTextStyles.bodySm(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Kepala langkah menu: avatar + nama akun + ringkas data. Nama yang
  /// tampil adalah NAMA AKUN (bukan nama profil) karena itulah yang
  /// diubah aksi "Ubah Nama Akun" tepat di bawahnya.
  Widget _menuHeader() {
    final profile = _activeIn(widget.profiles) ??
        (widget.profiles.isEmpty ? null : widget.profiles.first);
    return Row(
      children: [
        _ProfileAvatar(
          profile: profile,
          radius: 28,
          textStyle: AppTextStyles.headlineMd(),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.accountName,
                style: AppTextStyles.headlineMd(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                AppStrings.fill('profileStats', widget.lang, {
                  'w': widget.wallets,
                  't': widget.transactions,
                }),
                style: AppTextStyles.bodySm(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Tiga aksi, bukan daftar profil: ganti profil (menuju langkah
  /// berikutnya), ganti nama akun, dan keluar ke tab Pengaturan.
  Widget _menuActions(ProfileModel? active) {
    final lang = widget.lang;
    final rows = <Widget>[
      _ActionRow(
        icon: Icons.swap_horiz_outlined,
        // Aksi-account diberi aksen karena satu-satunya yang diam-diam
        // menukar seluruh ruang data.
        accent: true,
        title: AppStrings.get('changeAccount', lang),
        // Satu profil: jangan menjanjikan pilihan. Keterangan berubah
        // jadi siapa yang sedang aktif — barisnya tetap hidup dan
        // jujur membuka daftar, bukan jadi kontrol mati.
        subtitle: _onlyOne
            ? (active?.name ?? '')
            : AppStrings.get('changeAccountDesc', lang),
        trailing: const Icon(
          Icons.chevron_right,
          size: 20,
          color: AppColors.outline,
        ),
        onTap: _toList,
      ),
      _ActionRow(
        icon: Icons.edit_outlined,
        title: AppStrings.get('editAccount', lang),
        subtitle: widget.accountName,
        onTap: () => _closeThen(widget.onRename),
      ),
      const _RowRule(),
      _ActionRow(
        icon: Icons.settings_outlined,
        title: AppStrings.get('openSettings', lang),
        onTap: () => _closeThen(widget.onOpenSettings),
      ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++)
          StaggerEntrance(
            // Key unik: tanpa ini tiap build ulang sheet akan memutar
            // ulang animasi masuk untuk semua baris.
            key: ValueKey('menu-$i'),
            index: i,
            child: rows[i],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeIn(widget.profiles) ??
        (widget.profiles.isEmpty ? null : widget.profiles.first);
    return PopScope(
      // Back sistem di langkah daftar berarti "kembali ke menu", bukan
      // menutup sheet.
      //
      // CATATAN perilaku yang mudah salah: `canPop: false`
      // memblokir SELURUH jalur pop yang lewat `maybePop` — termasuk tap
      // barrier, karena ModalBarrier memakai Navigator.maybePop
      // (widgets/modal_barrier.dart). Jadi saat di langkah daftar, tap
      // area gelap pun mengembalikan ke menu, bukan menutup. Yang tetap
      // menutup sheet cuma drag ke bawah (BottomSheet.onClosing memakai
      // Navigator.pop langsung, tanpa mengecek popDisposition). Itu
      // disengaja: sheet dua tingkat di Android juga kembali satu level
      // saat area gelap ditekan. Jangan diubah tanpa alasan yang sama.
      canPop: !_listing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _toMenu();
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: AnimatedSize(
            // Morph tinggi: sheet terasa mengikuti hierarki menu → daftar
            // alih-alih melompat.
            duration: AppMotion.durationFor(context, AppMotion.medium),
            curve: AppMotion.sheet,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SheetHandle(),
                AnimatedSize(
                  duration: AppMotion.durationFor(context, AppMotion.fast),
                  curve: AppMotion.sheet,
                  alignment: Alignment.topCenter,
                  child: _listing ? _listHeader() : _menuHeader(),
                ),
                const SizedBox(height: 8),
                _listing
                    ? _ProfileList(
                        lang: widget.lang,
                        profiles: widget.profiles,
                        outer: widget.outer,
                        onlyOne: _onlyOne,
                      )
                    : _menuActions(active),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Daftar profil pada langkah "Ubah Akun".
///
/// Alur ganti profil sengaja tidak diubah dari versi sebelumnya: ketuk
/// akun tujuan → sheet ditutup dulu → verifikasi PIN bila profil target
/// diproteksi → seluruh state dimuat ulang dari ruang profil tersebut
/// (lihat [switchActiveProfile]).
class _ProfileList extends StatelessWidget {
  final String lang;
  final List<ProfileModel> profiles;

  /// Konteks luar sheet — dipakai SETELAH sheet ditutup, itu sebabnya
  /// ini bukan `context` milik daftar ini.
  final BuildContext outer;

  /// Hanya satu profil (atau registry kosong): isi langkah ini tak punya
  /// pilihan untuk ditampilkan, jadi sheet harus jujur mengatakannya.
  final bool onlyOne;

  const _ProfileList({
    required this.lang,
    required this.profiles,
    required this.outer,
    required this.onlyOne,
  });

  @override
  Widget build(BuildContext context) {
    final activeId = ProfileService.activeId;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < profiles.length; i++)
          StaggerEntrance(
            key: ValueKey('profile-$i'),
            index: i,
            child: _ProfileRow(
              lang: lang,
              profile: profiles[i],
              active: profiles[i].id == activeId,
              // Dengan satu profil, centang saja tak menjelaskan apa pun:
              // label "Profil aktif" yang memberi tahu tak ada lainnya.
              showActiveLabel: onlyOne,
              onTap: profiles[i].id == activeId
                  ? null
                  : () {
                      // Pop dulu, baru switch — sheet PIN profil target
                      // harus muncul tanpa daftar akun yang masih
                      // menutupinya.
                      Navigator.of(context).pop();
                      unawaited(switchActiveProfile(outer, profiles[i].id));
                    },
            ),
          ),
        if (onlyOne) ...[
          const SizedBox(height: 8),
          // Catatan penuntun: dua key yang sudah ada disusun jadi satu
          // kalimat pendek ("Tambah profil • Buka Pengaturan") alih-alih
          // mengarang string baru di l10n.
          Row(
            children: [
              const Icon(
                Icons.info_outline,
                size: 14,
                color: AppColors.outline,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${AppStrings.get('addProfile', lang)}'
                  ' • ${AppStrings.get('openSettings', lang)}',
                  style: AppTextStyles.bodySm(),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Satu baris profil di daftar. Baris aktif tak bisa diketuk (tak ada
/// yang perlu beralih ke dirinya sendiri) dan ditandai centang.
class _ProfileRow extends StatelessWidget {
  final String lang;
  final ProfileModel profile;
  final bool active;
  final bool showActiveLabel;
  final VoidCallback? onTap;

  const _ProfileRow({
    required this.lang,
    required this.profile,
    required this.active,
    required this.showActiveLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: Color(profile.color),
        child: Text(
          _initialOf(profile.name),
          style: AppTextStyles.bodyMd().copyWith(color: Colors.white),
        ),
      ),
      title: Text(
        profile.name,
        style: AppTextStyles.bodyMd(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: showActiveLabel && active
          ? Text(
              AppStrings.get('activeProfile', lang),
              style: AppTextStyles.bodySm(),
            )
          : null,
      trailing:
          active ? const Icon(Icons.check, color: AppColors.tertiary) : null,
      onTap: onTap,
    );
  }
}

/// Baris aksi di menu profil: ikon + judul + keterangan opsional.
class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Icon? trailing;

  /// Aksi-account (ganti profil) memakai aksen hijau: satu-satunya aksi
  /// yang menukar seluruh ruang data tanpa terlihat sepele.
  final bool accent;

  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        icon,
        size: 22,
        color: accent ? AppColors.tertiary : AppColors.onSurfaceVariant,
      ),
      title: Text(title, style: AppTextStyles.bodyMd()),
      subtitle: (subtitle == null || subtitle!.isEmpty)
          ? null
          : Text(
              subtitle!,
              style: AppTextStyles.bodySm(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// Garis pemisah tipis: memisahkan "apa yang bisa diubah di sini" dari
/// aksi yang benar-benar membawa pengguna keluar dari sheet.
class _RowRule extends StatelessWidget {
  const _RowRule();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: AppColors.outlineVariant,
    );
  }
}

/// Avatar profil: satu lingkaran warna + inisial, dipakai di header dan
/// kepala sheet menu.
class _ProfileAvatar extends StatelessWidget {
  final ProfileModel? profile;
  final double radius;
  final TextStyle textStyle;

  const _ProfileAvatar({
    required this.profile,
    required this.radius,
    required this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    // Tanpa profil: warna utama + "?" — bukan lingkaran kosong yang
    // menyamar sebagai profil sungguhan.
    final pr = profile;
    return CircleAvatar(
      radius: radius,
      backgroundColor: pr == null ? AppColors.primary : Color(pr.color),
      child: Text(
        _initialOf(pr?.name ?? ''),
        style: textStyle.copyWith(color: Colors.white),
      ),
    );
  }
}

/// Dialog ubah nama akun.
///
/// Stateful supaya [TextEditingController]-nya dibuang saat dialog ditutup;
/// sebelumnya controller dibuat di dalam callback tile dan tak pernah
/// dilepas (bocor tiap kali dialog dibuka).
///
/// Gagal menyimpan TIDAK menutup dialog — menutupnya akan terasa seperti
/// "tersimpan" padahal belum.
class _RenameAccountDialog extends StatefulWidget {
  final String lang;
  final String initialName;
  final FinanceProvider fp;
  final ScaffoldMessengerState messenger;

  const _RenameAccountDialog({
    required this.lang,
    required this.initialName,
    required this.fp,
    required this.messenger,
  });

  @override
  State<_RenameAccountDialog> createState() => _RenameAccountDialogState();
}

class _RenameAccountDialogState extends State<_RenameAccountDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final raw = _ctrl.text.trim();
    final name = raw.isEmpty ? 'Kaji Finance' : raw;
    try {
      await widget.fp.setAccountName(name);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (_) {
      // Penyimpanan gagal → dialog tetap terbuka agar tak terasa
      // tersimpan.
      if (!mounted) return;
      widget.messenger.showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('genericError', widget.lang)),
          backgroundColor: AppColors.errorContainer,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.lang;
    return AlertDialog(
      backgroundColor: AppColors.surfaceContainer,
      title: Text(
        AppStrings.get('editAccount', lang),
        style: AppTextStyles.headlineSm(),
      ),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(
          hintText: AppStrings.get('accountNameHint', lang),
        ),
        style: AppTextStyles.bodyMd(),
        onSubmitted: (_) => unawaited(_save()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.get('cancel', lang)),
        ),
        ElevatedButton(
          onPressed: () => unawaited(_save()),
          child: Text(AppStrings.get('save', lang)),
        ),
      ],
    );
  }
}

part of '../../settings_screen.dart';

/// Pembantu tampilan bersama semua seksi Pengaturan (batch 1, pindahan
/// verbatim dari settings_screen.dart): kerangka seksi + baris tile.
extension _SettingsSectionWidgets on _SettingsScreenState {
  Widget _section(String title, List<Widget> children) {
    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i < children.length - 1) {
        separated.add(
          Divider(
            height: 1,
            thickness: 0.6,
            indent: 56,
            endIndent: 16,
            color: AppColors.outlineVariant.withValues(alpha: 0.45),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Text(title, style: AppTextStyles.labelCaps()),
        ),
        Material(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.outlineVariant.withValues(alpha: 0.35),
                width: 0.6,
              ),
            ),
            child: Column(children: separated),
          ),
        ),
      ],
    );
  }

  Widget _tile(
    IconData icon,
    String title,
    String subtitle, {
    Widget? trailing,
    VoidCallback? onTap,
  }) =>
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        visualDensity: VisualDensity.comfortable,
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppColors.onSurfaceVariant, size: 19),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodyMd().copyWith(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodySm(),
        ),
        trailing: trailing ??
            const Icon(Icons.chevron_right, color: AppColors.outline, size: 18),
        onTap: onTap,
      );
}

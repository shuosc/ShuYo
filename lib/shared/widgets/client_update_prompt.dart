import 'package:material_ui/material_ui.dart';

import '../../core/client_app_info.dart';
import '../../data/models/client_backend.dart';
import '../../data/services/app_store_version_service.dart';
import '../theme/shuyo_theme.dart';

Future<bool> showClientUpdatePrompt(
  BuildContext context, {
  required ClientUpdateInfo update,
}) async {
  final openDownload = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final colors = dialogContext.shuyoColors;
      return AlertDialog(
        title: Text(update.updateTitle),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('当前版本：${ClientAppInfo.version}'),
              const SizedBox(height: 8),
              Text('最新版本：${update.latestVersion}'),
              if (update.updateMessage.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(update.updateMessage),
              ],
              if (update.noticeText.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  update.noticeText,
                  style: TextStyle(color: colors.textSecondary),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (update.hasDownloadUrl)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('更新'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
  return openDownload ?? false;
}

Future<bool> showAppStoreUpdatePrompt(
  BuildContext context, {
  required AppStoreVersionInfo update,
}) async {
  final openAppStore = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('App Store 有新版本'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前版本：${ClientAppInfo.version}'),
            const SizedBox(height: 8),
            Text('最新版本：${update.version}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('前往 App Store'),
          ),
        ],
      );
    },
  );
  return openAppStore ?? false;
}

import 'package:material_ui/material_ui.dart';
import '../../core/campus_system.dart';
import '../../data/services/student_identity_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../auth/native_login_page.dart';

class PrivacyDataPage extends StatelessWidget {
  const PrivacyDataPage({
    super.key,
    required this.identityService,
    required this.campusSystem,
    this.isDemo = false,
  }) : assert(isDemo || identityService != null);

  final StudentIdentityService? identityService;
  final CampusSystem campusSystem;
  final bool isDemo;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('隐私与数据')),
        body: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Text(
                isDemo
                    ? '当前为演示模式，所有演示数据仅保存在本地设备，不会在 ShuYo 服务器存储个人数据。登录真实校园账户后，可在此管理并删除服务器保存的数据。'
                    : 'ShuYo 向学校核实当前登录账号的学号。撤销设备认证后，服务器会保留你使用反馈、课表分享等功能产生的数据。',
              ),
            ),
            ListTile(
              key: const ValueKey('privacy-delete-data'),
              title: Text(
                '删除 ShuYo 数据',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push<void>(
                shuyoRoute(
                  builder: (_) => _DeleteShuYoDataPage(
                    identityService: identityService,
                    campusSystem: campusSystem,
                    isDemo: isDemo,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

class _DeleteShuYoDataPage extends StatefulWidget {
  const _DeleteShuYoDataPage({
    required this.identityService,
    required this.campusSystem,
    this.isDemo = false,
  }) : assert(isDemo || identityService != null);

  final StudentIdentityService? identityService;
  final CampusSystem campusSystem;
  final bool isDemo;

  @override
  State<_DeleteShuYoDataPage> createState() => _DeleteShuYoDataPageState();
}

class _DeleteShuYoDataPageState extends State<_DeleteShuYoDataPage> {
  bool _busy = false;
  bool _deleted = false;
  String? _message;

  Future<void> _verifyAndDelete() async {
    final identityService = widget.identityService;
    if (widget.isDemo || identityService == null) return;
    final grant = await Navigator.of(context).push<StudentDataDeletionGrant>(
      shuyoRoute(
        builder: (_) => NativeLoginPage.dataDeletion(
          studentIdentityService: identityService,
          deletionSystem: widget.campusSystem,
        ),
      ),
    );
    if (!mounted || grant == null) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认'),
            content: Text(
              '将删除学校核实的学号 ${grant.maskedStudentId} 对应的 ShuYo 数据。此操作不能撤销。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('确认删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await identityService.completeDataDeletion(grant);
      if (mounted) setState(() => _deleted = true);
    } on StudentIdentityException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on Object {
      if (mounted) setState(() => _message = '删除失败，请稍后再试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('删除 ShuYo 数据')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_deleted) ...[
              const Text('ShuYo 数据已删除。'),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
            ] else ...[
              Text(
                widget.isDemo
                    ? '当前为演示模式，未在 ShuYo 服务器保存个人数据。登录真实校园账户后，可在此验证学校身份并清除服务器保存的学号认证记录、反馈、活跃记录、课表分享码。'
                    : '删除后，你的设备认证将全部失效；服务器当前保存的学号认证记录、反馈、活跃记录、课表分享码将被清除。',
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('privacy-verify-deletion'),
                onPressed: widget.isDemo || _busy ? null : _verifyAndDelete,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(widget.isDemo ? '演示模式无云端数据' : '验证身份并继续'),
              ),
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(_message!),
              ],
            ],
          ],
        ),
      );
}

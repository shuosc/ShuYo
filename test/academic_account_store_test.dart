import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_account_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saving an account removes the legacy expiration marker', () async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.legacySessionExpiredKey: true,
    });
    final store = AcademicAccountStore();
    await store.saveStudentId('25120001');
    expect(await store.loadStudentId(), '25120001');
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.containsKey(AcademicAccountStore.legacySessionExpiredKey),
      isFalse,
    );
  });

  test('detects a legacy expired account for startup migration', () async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: '25120001',
      AcademicAccountStore.legacySessionExpiredKey: true,
    });
    final store = AcademicAccountStore();

    expect(await store.hasLegacyExpiredAccount(), isTrue);
    await store.clear();
    expect(await store.loadStudentId(), isNull);
    expect(await store.hasLegacyExpiredAccount(), isFalse);
  });

  test('logout removes the account and legacy expiration state', () async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: '25120001',
      AcademicAccountStore.legacySessionExpiredKey: true,
    });
    final store = AcademicAccountStore();

    await store.clear();

    expect(await store.loadStudentId(), isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.containsKey(AcademicAccountStore.legacySessionExpiredKey),
      isFalse,
    );
  });
}

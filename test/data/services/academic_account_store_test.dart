import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/campus_system.dart';
import 'package:shuyo/data/services/academic_account_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('only the selected system supplies the active account and expiry',
      () async {
    final store = AcademicAccountStore();
    await store.saveStudentId('undergrad-fixture');
    expect(await store.loadSystem(), CampusSystem.undergraduate);

    await store.saveStudentId('graduate-fixture',
        system: CampusSystem.graduate);
    expect(await store.loadStudentId(), 'undergrad-fixture');
    await store.saveSystem(CampusSystem.graduate);

    final reopened = AcademicAccountStore();
    expect(await reopened.loadSystem(), CampusSystem.graduate);
    expect(await reopened.loadStudentId(), 'graduate-fixture');
    await reopened.clear(system: CampusSystem.graduate, sessionExpired: true);
    expect(await reopened.loadStudentId(), isNull);
    expect(await reopened.loadDataStudentId(), 'graduate-fixture');
    expect(await reopened.isSessionExpired(), isTrue);

    await reopened.saveSystem(CampusSystem.undergraduate);
    expect(await reopened.loadStudentId(), 'undergrad-fixture');
    expect(await reopened.isSessionExpired(), isFalse);
  });

  test('first login is recorded per student before any data is fetched',
      () async {
    final store = AcademicAccountStore();
    await store.saveStudentId(' A ');
    expect(await store.takeInitialSync('A'), isTrue);
    await store.clear(sessionExpired: true);
    expect(await store.loadStudentId(), isNull);
    expect(await store.loadDataStudentId(), 'A');
    expect(await store.isSessionExpired(), isTrue);
    await store.saveStudentId('A');
    expect(await store.isSessionExpired(), isFalse);
    expect(await store.takeInitialSync('A'), isFalse);
    await store.clear();
    expect(await store.isSessionExpired(), isFalse);
    await store.saveStudentId('B');
    expect(await store.takeInitialSync('B'), isTrue);
    await store.saveStudentId('A');
    expect(await store.takeInitialSync('A'), isFalse);
  });

  test('upgrade recognizes an active account without a data cache', () async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: 'A',
    });
    final store = AcademicAccountStore();
    await store.rememberExistingAccounts();
    expect(await store.takeInitialSync('A'), isFalse);
    expect(await store.takeInitialSync('B'), isTrue);
  });

  test(
      'upgrade recognizes cached accounts after the active identity was cleared',
      () async {
    SharedPreferences.setMockInitialValues({
      'academic.schedule.cache': '{"term":{"studentId":"A"}}',
      'academic.progress.cache': '{"studentId":"B"}',
      'academic.ranking.cache': 'damaged cache',
    });
    final store = AcademicAccountStore();
    await store.rememberExistingAccounts();
    expect(await store.takeInitialSync('A'), isFalse);
    expect(await store.takeInitialSync('B'), isFalse);
    expect(await store.takeInitialSync('C'), isTrue);
  });

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

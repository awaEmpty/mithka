import 'package:flutter_test/flutter_test.dart';

import 'package:mithka/config/build_flags.dart';

void main() {
  // The fork opts into Telegram §1.4 exceptions by default; only an explicit
  // `false` turns them off, and an unreadable value keeps the default. CI
  // runs this file under all three define states.
  test('Telegram Section 1.4 exceptions follow the compile-time switch', () {
    const raw = String.fromEnvironment('I_DONT_FUCKING_CARE_ABOUT_TOS');
    expect(allowTelegramTosViolations, raw != 'false');
  });
}

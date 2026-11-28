import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/auth/login_view.dart';

/// The logout flicker: leaving an account runs the chain
/// AuthLoggingOut → AuthClosed → AuthInitializing → AuthWaitPhoneNumber.
/// The gate deliberately crossfades splash ⇄ login across that chain, but
/// inside the login surface every one of those tail states renders the SAME
/// phone-number column — re-keying the step's AnimatedSwitcher child on each
/// hop mounted a second copy of the form and cross-faded it against itself.
/// The identity must stay 'phone' across the whole chain.
void main() {
  test('the logout chain never re-keys the phone form', () {
    const chain = [AuthInitializing(), AuthWaitPhoneNumber(), AuthClosed()];
    final identities = chain.map(LoginView.debugStepIdentityForTesting).toSet();
    expect(identities, {'phone'});
  });

  test('a reload keeps the form that is already on screen', () async {
    // Cancel-add-account / logout run form → AuthReloading → gate hand-off.
    // The reloading state must not swap the code/2FA form back to the phone
    // column mid-flight (a displaced phone form that vanished last). The
    // state layer holds the last real form step until the page is gone.
    final source = await File('lib/auth/login_view.dart').readAsString();
    final sticky = source.indexOf('AuthStep _stickyStep(');
    expect(sticky, greaterThan(0), reason: 'the sticky step must exist');
    expect(
      source,
      contains('return _lastFormStep ?? step;'),
      reason: 'a non-form step falls back to the last form actually shown',
    );
    final identity = source.indexOf('String _stepIdentity(');
    expect(identity, greaterThan(0));
    expect(
      source.indexOf('_stickyStep(auth)', identity),
      greaterThan(identity),
      reason: 'the key must follow the step the page actually renders',
    );
  });

  test('distinct forms keep distinct identities', () {
    expect(
      LoginView.debugStepIdentityForTesting(
        const AuthWaitCode(
          AuthCodeInfo(method: AuthCodeDeliveryMethod.sms, length: 5),
        ),
      ),
      isNot('phone'),
    );
    expect(
      LoginView.debugStepIdentityForTesting(const AuthWaitQrCode('a')),
      isNot('phone'),
    );
  });

  test('mounting mid-reload seeds the phone column', () async {
    // Add-account mounts LoginView while the gate rides the splash→login
    // hand-off through AuthReloading. Seeding the literal "AuthReloading"
    // made the key flip to "phone" when the real form arrived a few hundred
    // ms later — the switcher cross-faded the same form against itself.
    final source = await File('lib/auth/login_view.dart').readAsString();
    expect(
      source,
      contains('_lastFormStep = const AuthWaitPhoneNumber();'),
      reason: 'initState must seed the phone form for a reload mount',
    );
    expect(
      source,
      contains('static bool _isLoginFormStep(AuthStep step)'),
      reason: 'only a real login form updates the sticky step',
    );
  });
}

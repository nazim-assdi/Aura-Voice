import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/app.dart';

void main() {
  testWidgets('shows the secure sign-in gate until the backend is configured', (tester) async {
    await tester.pumpWidget(const AuraVoiceApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Welcome to Aura Voice'), findsOneWidget);
    expect(find.text('Secure accounts are not configured yet'), findsOneWidget);
    expect(find.text('Sign in securely'), findsOneWidget);
    expect(find.text('Sign in to access your private voice projects and production tools.'), findsOneWidget);
  });
}

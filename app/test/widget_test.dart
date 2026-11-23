import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/app.dart';

void main() {
  testWidgets('renders Aura Voice Studio app shell', (tester) async {
    await tester.pumpWidget(const AuraVoiceApp());
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('AURA'), findsOneWidget);
    expect(find.text('VOICE STUDIO'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('AI Voice'), findsOneWidget);
  });
}

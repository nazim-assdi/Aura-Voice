import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/app.dart';

void main() {
  testWidgets('renders Aura Voice AI app shell', (tester) async {
    await tester.pumpWidget(const AuraVoiceApp());
    expect(find.text('AURA'), findsOneWidget);
    expect(find.text('VOICE AI'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
  });
}

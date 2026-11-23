import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/app.dart';

void main() {
  testWidgets('renders responsive Aura Voice Studio workspaces', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const AuraVoiceApp());
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('AURA'), findsOneWidget);
    expect(find.text('VOICE STUDIO'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('AI Voice'), findsOneWidget);
  });
}

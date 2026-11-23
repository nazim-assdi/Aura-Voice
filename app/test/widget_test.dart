import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/app.dart';

void _setDesktopViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
}

void _resetViewport(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

void main() {
  testWidgets('renders responsive Aura Voice Studio workspaces', (tester) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(const AuraVoiceApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('AURA'), findsOneWidget);
    expect(find.text('VOICE STUDIO'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('AI Voice'), findsOneWidget);
  });

  testWidgets('Dashboard opens the multitrack library workspace', (tester) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(const AuraVoiceApp());
    await tester.pump(const Duration(milliseconds: 100));

    final editorCard = find.text('Multitrack Editor');
    expect(editorCard, findsOneWidget);
    await tester.ensureVisible(editorCard);
    await tester.tap(editorCard);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Audio Library'), findsOneWidget);
    expect(find.byTooltip('New project'), findsOneWidget);
    expect(find.byTooltip('Open saved sessions'), findsOneWidget);
  });

  testWidgets('New project opens the editor and track controls update the session', (tester) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(const AuraVoiceApp());
    await tester.pump(const Duration(milliseconds: 100));

    final editorCard = find.text('Multitrack Editor');
    await tester.ensureVisible(editorCard);
    await tester.tap(editorCard);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();

    final newProjectTooltip = find.byTooltip('New project');
    expect(newProjectTooltip, findsOneWidget);
    final newProjectButton = find.descendant(
      of: newProjectTooltip,
      matching: find.byType(IconButton),
    );
    expect(newProjectButton, findsOneWidget);
    expect(
      tester.widget<IconButton>(newProjectButton).onPressed,
      isNotNull,
    );
    await tester.tap(newProjectButton);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Untitled Session'), findsOneWidget);
    expect(find.text('TRACKS / TIMELINE'), findsOneWidget);
    expect(find.text('Voice 1'), findsOneWidget);
    expect(find.byTooltip('Add track'), findsOneWidget);
    expect(find.byTooltip('Save session'), findsOneWidget);

    await tester.tap(find.byTooltip('Add track'));
    await tester.pump();
    expect(find.text('Voice 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Save session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Project saved with packaged media assets.'), findsOneWidget);
  });
}

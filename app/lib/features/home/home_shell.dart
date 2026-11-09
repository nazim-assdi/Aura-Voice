import 'package:flutter/material.dart';

import '../../core/services/api_client.dart';
import '../../core/theme/aura_theme.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      DashboardPage(onOpenStudio: () => setState(() => _index = 1)),
      const StudioPage(),
      const LibraryPage(),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _index, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.grid_view_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.graphic_eq_rounded), label: 'Studio'),
          NavigationDestination(icon: Icon(Icons.library_music_rounded), label: 'Library'),
        ],
      ),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({required this.onOpenStudio, super.key});
  final VoidCallback onOpenStudio;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              const _TopBar(),
              const SizedBox(height: 34),
              Text('YOUR CREATIVE AUDIO SPACE',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AuraTheme.mint, letterSpacing: 2.1, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text('Every voice has\na new dimension.',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    height: 1.06, fontWeight: FontWeight.w800, letterSpacing: -1.1)),
              const SizedBox(height: 22),
              _HeroPanel(onOpenStudio: onOpenStudio),
              const SizedBox(height: 26),
              Row(children: [
                Text('Your workspace',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                const _StatusChip(label: 'FOUNDATION'),
              ]),
              const SizedBox(height: 14),
              LayoutBuilder(builder: (context, constraints) {
                final columns = constraints.maxWidth > 720 ? 4 : 2;
                final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
                const features = [
                  _FeatureData(Icons.record_voice_over_rounded, 'Voice Studio', 'Speech workspace', AuraTheme.mint),
                  _FeatureData(Icons.tune_rounded, 'Emotion Lab', 'Style controls', AuraTheme.violet),
                  _FeatureData(Icons.multitrack_audio_rounded, 'Audio Tools', 'Edit and export', Color(0xFFFFC27A)),
                  _FeatureData(Icons.translate_rounded, 'AI Dubbing', 'Voice and language', Color(0xFF80B8FF)),
                ];
                return Wrap(
                  spacing: 12, runSpacing: 12,
                  children: features.map((f) => SizedBox(width: width, child: _FeatureCard(data: f))).toList(),
                );
              }),
              const SizedBox(height: 24),
              const _ApiStatusPanel(),
              const SizedBox(height: 18),
              Text(
                'Foundation preview · Speech models and voice processing are not connected yet.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AuraTheme.muted, height: 1.5),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();
  @override
  Widget build(BuildContext context) => Row(children: [
    Container(
      width: 42, height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(colors: [AuraTheme.mint, AuraTheme.violet]),
      ),
      child: const Icon(Icons.graphic_eq_rounded, color: Color(0xFF0B1421), size: 25),
    ),
    const SizedBox(width: 12),
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('AURA', style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w900, letterSpacing: 2.5)),
      Text('VOICE AI', style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: AuraTheme.muted, letterSpacing: 2.2)),
    ]),
    const Spacer(),
    const _StatusChip(label: 'HYBRID'),
    const SizedBox(width: 8),
    const CircleAvatar(radius: 19, backgroundColor: AuraTheme.panelLight,
      child: Icon(Icons.person_outline_rounded, color: Colors.white70)),
  ]);
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({required this.onOpenStudio});
  final VoidCallback onOpenStudio;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      gradient: const LinearGradient(
        colors: [Color(0xFF183447), Color(0xFF25264A), Color(0xFF171C32)],
        begin: Alignment.topLeft, end: Alignment.bottomRight),
      border: Border.all(color: Colors.white.withOpacity(0.09)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const _StatusChip(label: 'CREATIVE STUDIO'),
        const Spacer(),
        Icon(Icons.auto_awesome_rounded, color: AuraTheme.mint.withOpacity(0.9)),
      ]),
      const SizedBox(height: 28),
      Text('Shape sound.\nExpress more.',
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800, height: 1.08)),
      const SizedBox(height: 10),
      Text('A single workspace for voice, emotion and audio creation.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70, height: 1.5)),
      const SizedBox(height: 22),
      FilledButton.icon(
        onPressed: onOpenStudio,
        icon: const Icon(Icons.arrow_forward_rounded),
        label: const Text('Open Voice Studio'),
        style: FilledButton.styleFrom(
          backgroundColor: AuraTheme.mint, foregroundColor: const Color(0xFF07151A),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
      ),
    ]),
  );
}

class _FeatureData {
  const _FeatureData(this.icon, this.title, this.subtitle, this.accent);
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.data});
  final _FeatureData data;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: AuraTheme.panel, borderRadius: BorderRadius.circular(19),
      border: Border.all(color: Colors.white.withOpacity(0.055))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        height: 38, width: 38,
        decoration: BoxDecoration(color: data.accent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12)),
        child: Icon(data.icon, color: data.accent, size: 21)),
      const SizedBox(height: 18),
      Text(data.title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(data.subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AuraTheme.muted)),
      const SizedBox(height: 12),
      Text('PLANNED', style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: AuraTheme.muted, letterSpacing: 1.2)),
    ]),
  );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.07), borderRadius: BorderRadius.circular(30),
      border: Border.all(color: Colors.white.withOpacity(0.07))),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Colors.white70, letterSpacing: 1.1, fontWeight: FontWeight.w700)),
  );
}

class _ApiStatusPanel extends StatelessWidget {
  const _ApiStatusPanel();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(color: AuraTheme.panel, borderRadius: BorderRadius.circular(18)),
    child: Row(children: [
      const Icon(Icons.cloud_outlined, color: AuraTheme.mint),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Hybrid engine connection', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 3),
        Text('Backend availability check',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AuraTheme.muted)),
      ])),
      FutureBuilder<bool>(
        future: const ApiClient().isApiHealthy(),
        builder: (context, snapshot) {
          final label = snapshot.connectionState != ConnectionState.done
              ? 'CHECKING' : snapshot.data == true ? 'API ONLINE' : 'API OFFLINE';
          return _StatusChip(label: label);
        },
      ),
    ]),
  );
}

class StudioPage extends StatelessWidget {
  const StudioPage({super.key});
  @override
  Widget build(BuildContext context) => const _ComingSoonPage(
    icon: Icons.graphic_eq_rounded, title: 'Voice Studio',
    description: 'The studio shell is ready. Speech generation, voice enrollment and audio processing will appear here after the engine and consent layers are connected.',
  );
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});
  @override
  Widget build(BuildContext context) => const _ComingSoonPage(
    icon: Icons.library_music_rounded, title: 'Your Library',
    description: 'Voice profiles, generated audio and project exports will be stored here when secure account storage is implemented.',
  );
}

class _ComingSoonPage extends StatelessWidget {
  const _ComingSoonPage({required this.icon, required this.title, required this.description});
  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 76, height: 76,
            decoration: BoxDecoration(color: AuraTheme.panelLight, borderRadius: BorderRadius.circular(24)),
            child: Icon(icon, size: 36, color: AuraTheme.mint)),
          const SizedBox(height: 22),
          Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text(description, textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AuraTheme.muted, height: 1.6)),
          const SizedBox(height: 18),
          const _StatusChip(label: 'IN DEVELOPMENT'),
        ]),
      ),
    ),
  );
}

import 'package:material_ui/material_ui.dart';

import '../../core/theme/aura_theme.dart';

import '../../core/services/api_client.dart';
import '../home/home_shell.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _api = const ApiClient();
  bool _loading = true;
  bool _authReady = false;
  Map<String, dynamic>? _user;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final health = await _api.getHealthStatus();
    Map<String, dynamic>? user;
    if (health.authReady) {
      try {
        user = await _api.currentUser();
      } catch (_) {
        user = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _authReady = health.authReady;
      _user = user;
      _loading = false;
    });
  }

  void _onAuthenticated(Map<String, dynamic> user) {
    setState(() => _user = user);
  }

  Future<void> _signOut() async {
    try {
      await _api.logout();
    } finally {
      if (mounted) setState(() => _user = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final user = _user;
    if (user != null) {
      return HomeShell(onSignOut: _signOut);
    }
    return _MobileAuthPage(
      api: _api,
      authReady: _authReady,
      onAuthenticated: _onAuthenticated,
      onRetry: _restoreSession,
    );
  }
}

class _MobileAuthPage extends StatefulWidget {
  const _MobileAuthPage({
    required this.api,
    required this.authReady,
    required this.onAuthenticated,
    required this.onRetry,
  });

  final ApiClient api;
  final bool authReady;
  final ValueChanged<Map<String, dynamic>> onAuthenticated;
  final Future<void> Function() onRetry;

  @override
  State<_MobileAuthPage> createState() => _MobileAuthPageState();
}

class _MobileAuthPageState extends State<_MobileAuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _registering = false;
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!widget.authReady || _busy || !_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = _registering
          ? await widget.api.register(
              name: _name.text.trim(),
              email: _email.text.trim(),
              password: _password.text,
            )
          : await widget.api.login(
              email: _email.text.trim(),
              password: _password.text,
            );
      widget.onAuthenticated(user);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AuraTheme.panel,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        alignment: Alignment.center,
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AuraTheme.mint, AuraTheme.violet],
                          ),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(
                          Icons.graphic_eq_rounded,
                          color: Color(0xFF0B1421),
                          size: 30,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _registering ? 'Create your Aura account' : 'Welcome to Aura Voice',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Sign in to access your private voice projects and production tools.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AuraTheme.muted,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (!widget.authReady)
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(color: Colors.amber.withValues(alpha: 0.24)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.lock_outline_rounded, color: Colors.amber),
                                  SizedBox(width: 9),
                                  Expanded(
                                    child: Text(
                                      'Secure accounts are not configured yet',
                                      style: TextStyle(
                                        color: Colors.amber,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'The backend needs a durable PostgreSQL database and a 32+ character JWT secret. Sign-in and paid voice-generation endpoints stay locked until the server is configured.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AuraTheme.muted,
                                  height: 1.55,
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: _busy ? null : widget.onRetry,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('Check again'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_registering) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _name,
                          maxLength: 80,
                          decoration: const InputDecoration(
                            labelText: 'Your name',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                          validator: (value) {
                            if (_registering && (value == null || value.trim().length < 2)) {
                              return 'Enter at least two characters.';
                            }
                            return null;
                          },
                        ),
                      ],
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.username, AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        validator: (value) {
                          final email = value?.trim() ?? '';
                          if (!email.contains('@') || !email.contains('.')) {
                            return 'Enter a valid email address.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscurePassword,
                        autofillHints: _registering
                            ? const [AutofillHints.newPassword]
                            : const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                            icon: Icon(_obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                          ),
                        ),
                        validator: (value) {
                          final password = value ?? '';
                          if (_registering && password.length < 10) {
                            return 'Use at least 10 characters.';
                          }
                          if (password.isEmpty) return 'Enter your password.';
                          return null;
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _error!,
                          style: theme.textTheme.bodySmall?.copyWith(color: Colors.redAccent),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        onPressed: !_busy && widget.authReady ? _submit : null,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.arrow_forward_rounded),
                        label: Text(
                          _busy
                              ? 'Please wait…'
                              : _registering
                                  ? 'Create account'
                                  : 'Sign in securely',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: AuraTheme.mint,
                          foregroundColor: const Color(0xFF07151A),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _registering = !_registering;
                                  _error = null;
                                }),
                        child: Text(
                          _registering
                              ? 'Already have an account? Sign in'
                              : 'New to Aura Voice? Create an account',
                        ),
                      ),
                      Text(
                        'Your session is stored using platform secure storage. The Cartesia API key never enters the mobile app.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AuraTheme.muted,
                          fontSize: 10,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

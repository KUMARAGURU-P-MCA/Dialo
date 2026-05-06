import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_service.dart';
import 'audio_handler.dart';

// ── Configuration ─────────────────────────────────────────────────────────────
const String wsBaseUrl = 'ws://10.168.48.49:8000';

// ── App Entry ─────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VoiceAgentApp());
}

class VoiceAgentApp extends StatelessWidget {
  const VoiceAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PTT Voice Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light, 
        colorSchemeSeed: const Color(0xFF6C63FF),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const RootRouter(),
    );
  }
}

// ── Root Router: decides between Onboarding and Main screen ───────────────────
class RootRouter extends StatefulWidget {
  const RootRouter({super.key});

  @override
  State<RootRouter> createState() => _RootRouterState();
}

class _RootRouterState extends State<RootRouter> {
  bool _checking = true;
  String? _userId;

  @override
  void initState() {
    super.initState();
    _checkExistingUser();
  }

  Future<void> _checkExistingUser() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('user_id');
    setState(() {
      _userId = savedId;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_userId == null) {
      return OnboardingScreen(onComplete: (userId) {
        setState(() => _userId = userId);
      });
    }
    return VoiceAgentScreen(userId: _userId!);
  }
}

// ════════════════════════════════════════════════════════════════════════════
// ONBOARDING SCREEN — Name + Language Selection
// ════════════════════════════════════════════════════════════════════════════

class OnboardingScreen extends StatefulWidget {
  final void Function(String userId) onComplete;
  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _nameController = TextEditingController();
  String _selectedLanguage = 'English'; // default
  bool _loading = false;
  String? _error;
  int _step = 0; 

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _createAccount() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter your name');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final user = await ApiService.createUser(
      name: name,
      baseLanguage: _selectedLanguage,
    );

    if (user == null) {
      setState(() {
        _loading = false;
        _error = 'Could not create account. Is the server running?';
      });
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_id', user.userId);
    await prefs.setString('user_name', user.name);

    widget.onComplete(user.userId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Let\'s set up your English learning journey.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: cs.onSurface.withAlpha(160),
                  ),
                ),

                const SizedBox(height: 56),

                AnimatedOpacity(
                  opacity: _step == 0 ? 1.0 : 0.4,
                  duration: const Duration(milliseconds: 300),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'What\'s your name?',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _nameController,
                        onTap: () => setState(() => _step = 0),
                        onSubmitted: (_) => setState(() => _step = 1),
                        textCapitalization: TextCapitalization.words,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: cs.onSurface,
                        ),
                        decoration: InputDecoration(
                          hintText: 'e.g. Arjun',
                          hintStyle: TextStyle(color: cs.onSurface.withAlpha(80)),
                          border: UnderlineInputBorder(
                            borderSide: BorderSide(color: cs.outline),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: cs.primary, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 48),

                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose your teaching language',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'This applies to Level 1 only. Levels 2 & 3 are always in English.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withAlpha(130),
                      ),
                    ),
                    const SizedBox(height: 20),

                    _LanguageCard(
                      label: 'English',
                      subtitle: 'Slow A1-level English explanations',
                      emoji: '🇬🇧',
                      selected: _selectedLanguage == 'English',
                      onTap: () => setState(() {
                        _selectedLanguage = 'English';
                        _step = 1;
                      }),
                    ),
                    const SizedBox(height: 12),
                    _LanguageCard(
                      label: 'Tamil',
                      subtitle: 'Grammar explained in Tamil — தமிழில்',
                      emoji: '🇮🇳',
                      selected: _selectedLanguage == 'Tamil',
                      onTap: () => setState(() {
                        _selectedLanguage = 'Tamil';
                        _step = 1;
                      }),
                    ),
                  ],
                ),

                const SizedBox(height: 48),

                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(color: cs.error),
                  ),
                  const SizedBox(height: 16),
                ],

                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _loading ? null : _createAccount,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      textStyle: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Start Learning →'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LanguageCard extends StatelessWidget {
  final String label;
  final String subtitle;
  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  const _LanguageCard({
    required this.label,
    required this.subtitle,
    required this.emoji,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? cs.primary : cs.outline.withAlpha(80),
            width: selected ? 2 : 1,
          ),
          color: selected ? cs.primary.withAlpha(25) : cs.surfaceContainerHighest,
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 32)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: selected ? cs.primary : cs.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withAlpha(150),
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, color: cs.primary)
            else
              Icon(Icons.circle_outlined, color: cs.outline.withAlpha(100)),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// VOICE AGENT SCREEN — Main PTT Interface
// ════════════════════════════════════════════════════════════════════════════

enum VoiceState { idle, connecting, listening, processing, aiSpeaking }

class VoiceAgentScreen extends StatefulWidget {
  final String userId;
  const VoiceAgentScreen({super.key, required this.userId});

  @override
  State<VoiceAgentScreen> createState() => _VoiceAgentScreenState();
}

class _VoiceAgentScreenState extends State<VoiceAgentScreen>
    with TickerProviderStateMixin {
  WebSocketChannel? _channel;
  bool _isConnected = false;

  String? _sessionId;
  int _sessionLevel = 1;
  String _sessionLevelName = 'Beginner';
  String _sessionLanguage = 'English';
  List<String> _sessionWords = [];

  final AudioHandler _audioHandler = AudioHandler();
  StreamSubscription? _micSub;

  VoiceState _voiceState = VoiceState.idle;
  String _statusText = 'Tap Connect to start';

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _audioHandler.onPlaybackComplete = () {
      debugPrint('[UI] Playback drain complete — switching to idle');
      _audioHandler.stopPlayback();
      _setStatus('Hold to speak', VoiceState.idle);
    };
  }

  @override
  void dispose() {
    _disconnect(navigatingToResults: false); // Make sure it doesn't try to navigate on dispose
    _audioHandler.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ── LOGOUT FUNCTIONALITY ────────────────────────────────────────────────
  Future<void> _logout() async {
    // 1. Disconnect without navigating to the results screen
    await _disconnect(navigatingToResults: false);
    
    // 2. Wipe the saved user data
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear(); 
    
    if (!mounted) return;
    
    // 3. Send the user back to the RootRouter (which will see no user and show Onboarding)
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const RootRouter()),
      (route) => false,
    );
  }
  // ────────────────────────────────────────────────────────────────────────

  Future<bool> _requestMicPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> _connect() async {
    if (_isConnected) return;

    final hasPermission = await _requestMicPermission();
    if (!hasPermission) {
      _setStatus('Microphone permission denied', VoiceState.idle);
      return;
    }

    _setStatus('Starting session...', VoiceState.connecting);

    final sessionResult = await ApiService.startSession(widget.userId);
    if (sessionResult == null) {
      _setStatus('Failed to start session. Is the server running?', VoiceState.idle);
      return;
    }

    _sessionId       = sessionResult.sessionId;
    _sessionLevel    = sessionResult.level;
    _sessionLevelName = sessionResult.levelName;
    _sessionLanguage = sessionResult.languageMode;
    _sessionWords    = sessionResult.words;

    try {
      _channel = WebSocketChannel.connect(
        Uri.parse('$wsBaseUrl/ws/${sessionResult.sessionId}'),
      );
      await _channel!.ready;

      setState(() {
        _isConnected = true;
        _statusText = 'Hold to speak';
        _voiceState = VoiceState.idle;
      });

      _channel!.stream.listen(
        (message) {
          if (message is List<int>) {
            _handleIncomingAudio(Uint8List.fromList(message));
          } else if (message is String) {
            _handleTextMessage(message);
          }
        },
        onDone: () {
          debugPrint('[WS] Connection closed');
          _disconnect(); // Defaults to true
        },
        onError: (error) {
          debugPrint('[WS] Error: $error');
          _disconnect();
        },
      );
    } catch (e) {
      debugPrint('[WS] Connection failed: $e');
      _setStatus('Connection failed: $e', VoiceState.idle);
    }
  }

  // Notice the added "navigatingToResults" flag so Logout doesn't trigger the grading screen
  Future<void> _disconnect({bool navigatingToResults = true}) async {
    _micSub?.cancel();
    _micSub = null;
    _audioHandler.stopRecording();
    _audioHandler.stopPlayback();

    final endedSessionId = _sessionId; 

    if (_sessionId != null) {
      await ApiService.endSession(
        userId: widget.userId,
        sessionId: _sessionId!,
      );
      _sessionId = null;
    }

    _channel?.sink.close();
    _channel = null;
    _pulseController.stop();

    if (!mounted) return;

    if (navigatingToResults && endedSessionId != null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => SessionResultScreen(
            sessionId: endedSessionId,
            userId: widget.userId,
          ),
        ),
      );
    } else {
      setState(() {
        _isConnected = false;
        _statusText = 'Tap Connect to start';
        _voiceState = VoiceState.idle;
        _sessionWords = [];
      });
    }
  }

  Future<void> _onPTTDown() async {
    if (!_isConnected || _channel == null || _voiceState != VoiceState.idle) {
      return;
    }

    await _audioHandler.stopPlayback();
    _setStatus('Listening...', VoiceState.listening);
    _pulseController.repeat(reverse: true);

    final stream = await _audioHandler.startRecording();
    if (stream == null) {
      _setStatus('Mic Permission Denied', VoiceState.idle);
      _pulseController.stop();
      _pulseController.reset();
      return;
    }

    _micSub = stream.listen((audioChunk) {
      if (_channel != null && audioChunk.isNotEmpty) {
        _channel!.sink.add(audioChunk);
      }
    });
  }

  Future<void> _onPTTUp() async {
    if (_voiceState != VoiceState.listening) return;

    await _micSub?.cancel();
    _micSub = null;
    await _audioHandler.stopRecording();
    _pulseController.stop();
    _pulseController.reset();

    if (_channel != null) {
      _channel!.sink.add(jsonEncode({'action': 'turn_complete'}));
      debugPrint('[PTT] Sent turn_complete');
    }

    _setStatus('Processing...', VoiceState.processing);
  }

  Future<void> _handleIncomingAudio(Uint8List audioData) async {
    if (_voiceState != VoiceState.aiSpeaking) {
      _setStatus('AI Speaking...', VoiceState.aiSpeaking);
    }
    await _audioHandler.feedPlayback(audioData);
  }

  void _handleTextMessage(String message) {
    try {
      final data = jsonDecode(message);
      if (data is Map && data['event'] == 'turn_complete') {
        final int chunks = (data['chunks'] as num?)?.toInt() ?? 0;
        debugPrint('[WS] Gemini turn complete — $chunks chunks');
        _audioHandler.scheduleDrainCallback(chunks);
      }
    } catch (_) {
      debugPrint('[WS] Non-JSON text: $message');
    }
  }

  void _setStatus(String text, VoiceState state) {
    if (!mounted) return;
    setState(() {
      _statusText = text;
      _voiceState = state;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 16),

              // ── Header (Title + Logout Button) ────────────────────────
              Stack(
                alignment: Alignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Voice Agent',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface,
                        ),
                      ),
                      if (_isConnected) ...[
                        const SizedBox(width: 12),
                        _LevelBadge(
                          level: _sessionLevel,
                          name: _sessionLevelName,
                        ),
                      ],
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      icon: const Icon(Icons.logout),
                      color: cs.error.withAlpha(200),
                      tooltip: 'Logout',
                      onPressed: _logout,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Direct Pipe • PTT',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withAlpha(100),
                ),
              ),

              if (_isConnected && _sessionWords.isNotEmpty) ...[
                const SizedBox(height: 20),
                _SessionInfoCard(
                  words: _sessionWords,
                  language: _sessionLanguage,
                ),
              ],

              const Spacer(),

              if (_isConnected) ...[
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _voiceState == VoiceState.listening
                          ? _pulseAnimation.value
                          : 1.0,
                      child: child,
                    );
                  },
                  child: Listener(
                    onPointerDown: (_) => _onPTTDown(),
                    onPointerUp: (_) => _onPTTUp(),
                    onPointerCancel: (_) => _onPTTUp(),
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _getPTTColor(),
                        boxShadow: [
                          BoxShadow(
                            color: _getPTTColor().withAlpha(100),
                            blurRadius: 30,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Center(
                        child: Icon(
                          _getPTTIcon(),
                          size: 48,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    _statusText,
                    key: ValueKey(_statusText),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: _getStatusColor(cs),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                TextButton.icon(
                  onPressed: () => _disconnect(navigatingToResults: true),
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('End Session'),
                  style: TextButton.styleFrom(foregroundColor: cs.error),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: _voiceState == VoiceState.connecting
                      ? null
                      : _connect,
                  icon: _voiceState == VoiceState.connecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cable),
                  label: Text(
                    _voiceState == VoiceState.connecting
                        ? 'Starting...'
                        : 'Start Session',
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    textStyle: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface.withAlpha(150),
                  ),
                ),
              ],

              const Spacer(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Color _getPTTColor() {
    switch (_voiceState) {
      case VoiceState.listening:
        return const Color(0xFFEF4444);
      case VoiceState.processing:
        return const Color(0xFFF59E0B);
      case VoiceState.aiSpeaking:
        return const Color(0xFF10B981);
      case VoiceState.idle:
      case VoiceState.connecting:
        return const Color(0xFF6C63FF);
    }
  }

  IconData _getPTTIcon() {
    switch (_voiceState) {
      case VoiceState.listening:
        return Icons.mic;
      case VoiceState.processing:
        return Icons.hourglass_top;
      case VoiceState.aiSpeaking:
        return Icons.volume_up;
      case VoiceState.idle:
      case VoiceState.connecting:
        return Icons.mic_none;
    }
  }

  Color _getStatusColor(ColorScheme cs) {
    switch (_voiceState) {
      case VoiceState.listening:
        return const Color(0xFFEF4444);
      case VoiceState.processing:
        return const Color(0xFFF59E0B);
      case VoiceState.aiSpeaking:
        return const Color(0xFF10B981);
      case VoiceState.idle:
      case VoiceState.connecting:
        return cs.onSurface.withAlpha(200);
    }
  }
}

class _LevelBadge extends StatelessWidget {
  final int level;
  final String name;
  const _LevelBadge({required this.level, required this.name});

  Color _color() {
    switch (level) {
      case 1: return const Color(0xFF10B981);   // green
      case 2: return const Color(0xFFF59E0B);   // amber
      case 3: return const Color(0xFF6C63FF);   // purple
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _color().withAlpha(40),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _color(), width: 1),
      ),
      child: Text(
        'Lv.$level $name',
        style: TextStyle(
          color: _color(),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SessionInfoCard extends StatefulWidget {
  final List<String> words;
  final String language;
  const _SessionInfoCard({required this.words, required this.language});

  @override
  State<_SessionInfoCard> createState() => _SessionInfoCardState();
}

class _SessionInfoCardState extends State<_SessionInfoCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outline.withAlpha(60)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.school_outlined, size: 16, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  "Today's words · ${widget.language}",
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: cs.onSurface.withAlpha(120),
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: widget.words.map((word) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary.withAlpha(20),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      word,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ] else ...[
              const SizedBox(height: 4),
              Text(
                widget.words.take(3).join(', ') +
                    (widget.words.length > 3 ? '  +${widget.words.length - 3} more' : ''),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withAlpha(150),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SESSION RESULT SCREEN — Polls backend with Fake Progress UX
// ════════════════════════════════════════════════════════════════════════════

class SessionResultScreen extends StatefulWidget {
  final String sessionId;
  final String userId;

  const SessionResultScreen({
    super.key,
    required this.sessionId,
    required this.userId,
  });

  @override
  State<SessionResultScreen> createState() => _SessionResultScreenState();
}

// Added SingleTickerProviderStateMixin for the progress bar animation
class _SessionResultScreenState extends State<SessionResultScreen> with SingleTickerProviderStateMixin {
  Timer? _pollTimer;
  bool _isLoading = true;
  int? _grammarScore;
  String? _feedbackSummary;
  Map<String, dynamic>? _wordsAssessment;

  late AnimationController _progressController;

  @override
  void initState() {
    super.initState();
    
    // Set up the animation controller for the "Creeping" Progress Bar
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    
    // Instantly shoot to 80% to make the user feel like it's fast
    _progressController.animateTo(0.80, curve: Curves.easeOutCubic);
    
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _progressController.dispose();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final result = await ApiService.getSessionResult(widget.sessionId);
      
      if (result != null && result['status'] == 'graded') {
        timer.cancel(); 
        
        // Shoot to 100% real quick before showing results!
        await _progressController.animateTo(1.0, duration: const Duration(milliseconds: 400));
        
        if (mounted) {
          final graderJson = result['grader_json'] as Map<String, dynamic>;
          setState(() {
            _isLoading = false;
            _grammarScore = result['grammar_score'];
            _feedbackSummary = graderJson['feedback_summary'];
            _wordsAssessment = graderJson['words_assessment'];
          });
        }
      } else if (result != null && result['status'] == 'failed') {
        timer.cancel();
        if (mounted) {
          setState(() {
            _isLoading = false;
            _feedbackSummary = "Grading failed. Please try another session.";
          });
        }
      } else {
        // We are still waiting. Creep the progress bar up slightly, capping at 95%
        if (_progressController.value < 0.95 && mounted) {
           _progressController.animateTo(
             _progressController.value + 0.03, 
             duration: const Duration(seconds: 1),
           );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: _isLoading
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // The Animated Progress Circle
                    SizedBox(
                      height: 60,
                      width: 60,
                      child: AnimatedBuilder(
                        animation: _progressController,
                        builder: (context, child) {
                          return CircularProgressIndicator(
                            value: _progressController.value,
                            strokeWidth: 6,
                            strokeCap: StrokeCap.round,
                            backgroundColor: cs.primary.withAlpha(40),
                            color: cs.primary,
                          );
                        }
                      ),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      'AI is grading your session...',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: cs.onSurface.withAlpha(150),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Analyzing grammar and vocabulary.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withAlpha(100),
                      ),
                    ),
                  ],
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.stars_rounded, size: 64, color: Colors.amber),
                    const SizedBox(height: 16),
                    Text(
                      'Session Complete!',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 32),

                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer.withAlpha(80),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'Grammar Score',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: cs.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '$_grammarScore / 10',
                            style: theme.textTheme.displayMedium?.copyWith(
                              color: cs.primary,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 24),

                    if (_feedbackSummary != null) ...[
                      Text(
                        'Feedback',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _feedbackSummary!,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: cs.onSurface.withAlpha(200),
                          height: 1.5,
                        ),
                      ),
                    ],

                    const Spacer(),

                    FilledButton(
                      onPressed: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (context) => VoiceAgentScreen(userId: widget.userId),
                          ),
                        );
                      },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        textStyle: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: const Text('Start New Session'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
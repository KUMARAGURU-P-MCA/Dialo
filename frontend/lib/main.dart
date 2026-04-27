import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'audio_handler.dart';

// ── Configuration ───────────────────────────────────────────────────────────
const String wsUrl = 'ws://10.31.146.49:8000/ws';
const int sampleRate = 16000;

// ── App Entry ───────────────────────────────────────────────────────────────
void main() {
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
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF6C63FF),
        useMaterial3: true,
      ),
      home: const VoiceAgentScreen(),
    );
  }
}

// ── Voice State ─────────────────────────────────────────────────────────────
enum VoiceState { idle, listening, processing, aiSpeaking }

// ── Main Screen ─────────────────────────────────────────────────────────────
class VoiceAgentScreen extends StatefulWidget {
  const VoiceAgentScreen({super.key});

  @override
  State<VoiceAgentScreen> createState() => _VoiceAgentScreenState();
}

class _VoiceAgentScreenState extends State<VoiceAgentScreen>
    with TickerProviderStateMixin {
  // ── WebSocket ──────────────────────────────────────────────────────────
  WebSocketChannel? _channel;
  bool _isConnected = false;

  // ── Audio Handler ────────────────────────────────────────────────────────
  final AudioHandler _audioHandler = AudioHandler();
  StreamSubscription? _micSub;

  // ── State ──────────────────────────────────────────────────────────────
  VoiceState _voiceState = VoiceState.idle;
  String _statusText = 'Tap Connect to start';

  // ── Animations ─────────────────────────────────────────────────────────
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
  }

  @override
  void dispose() {
    _disconnect();
    _audioHandler.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ── Request microphone permission ──────────────────────────────────────
  Future<bool> _requestMicPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  // ── Connect to backend WebSocket ───────────────────────────────────────
  Future<void> _connect() async {
    if (_isConnected) return;

    final hasPermission = await _requestMicPermission();
    if (!hasPermission) {
      _setStatus('Microphone permission denied', VoiceState.idle);
      return;
    }

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      await _channel!.ready;

      setState(() {
        _isConnected = true;
        _statusText = 'Connected — Hold to speak';
        _voiceState = VoiceState.idle;
      });

      // Listen for incoming messages from backend
      _channel!.stream.listen(
        (message) {
          if (message is List<int>) {
            // Raw PCM audio bytes from Gemini
            _handleIncomingAudio(Uint8List.fromList(message));
          } else if (message is String) {
            // Text messages (e.g., turn_complete notification)
            _handleTextMessage(message);
          }
        },
        onDone: () {
          debugPrint('[WS] Connection closed');
          _disconnect();
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

  // ── Disconnect ─────────────────────────────────────────────────────────
  void _disconnect() {
    _micSub?.cancel();
    _micSub = null;
    _audioHandler.stopRecording();
    _channel?.sink.close();
    _channel = null;

    if (mounted) {
      setState(() {
        _isConnected = false;
        _statusText = 'Tap Connect to start';
        _voiceState = VoiceState.idle;
      });
    }
    _pulseController.stop();
  }

  // ── PTT: Start recording ──────────────────────────────────────────────
  Future<void> _onPTTDown() async {
    if (!_isConnected || _channel == null || _voiceState != VoiceState.idle) return;

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

  // ── PTT: Stop recording + send turn_complete ──────────────────────────
  Future<void> _onPTTUp() async {
    if (_voiceState != VoiceState.listening) return;

    await _micSub?.cancel();
    _micSub = null;
    await _audioHandler.stopRecording();
    _pulseController.stop();
    _pulseController.reset();

    // Send turn_complete signal to backend
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({'action': 'turn_complete'}));
      debugPrint('[PTT] Sent turn_complete');
    }

    _setStatus('Processing...', VoiceState.processing);
  }

  // ── Handle incoming audio from Gemini ─────────────────────────────────
  Future<void> _handleIncomingAudio(Uint8List audioData) async {
    if (_voiceState != VoiceState.aiSpeaking) {
      _setStatus('AI Speaking...', VoiceState.aiSpeaking);
    }
    await _audioHandler.feedPlayback(audioData);
  }

  // ── Handle text messages from backend ─────────────────────────────────
  void _handleTextMessage(String message) {
    try {
      final data = jsonDecode(message);
      if (data is Map && data['event'] == 'turn_complete') {
        debugPrint('[WS] Gemini turn complete — ready for next PTT');
        _audioHandler.stopPlayback();
        _setStatus('Connected — Hold to speak', VoiceState.idle);
      }
    } catch (_) {
      debugPrint('[WS] Non-JSON text: $message');
    }
  }

  // ── Update status ─────────────────────────────────────────────────────
  void _setStatus(String text, VoiceState state) {
    if (!mounted) return;
    setState(() {
      _statusText = text;
      _voiceState = state;
    });
  }

  // ── UI ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Title ──────────────────────────────────────────────
              Text(
                'Voice Agent',
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Direct Pipe • Raw WebSocket • PTT',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface.withAlpha(150),
                ),
              ),

              const SizedBox(height: 60),

              // ── PTT Button ─────────────────────────────────────────
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
                  child: GestureDetector(
                    onTapDown: (_) => _onPTTDown(),
                    onTapUp: (_) => _onPTTUp(),
                    onTapCancel: () => _onPTTUp(),
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

                const SizedBox(height: 32),

                // ── Status Text ──────────────────────────────────────
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    _statusText,
                    key: ValueKey(_statusText),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: _getStatusColor(colorScheme),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

                const SizedBox(height: 48),

                // ── Disconnect Button ────────────────────────────────
                TextButton.icon(
                  onPressed: _disconnect,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Disconnect'),
                  style: TextButton.styleFrom(
                    foregroundColor: colorScheme.error,
                  ),
                ),
              ] else ...[
                // ── Connect Button ───────────────────────────────────
                FilledButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.cable),
                  label: const Text('Connect'),
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
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface.withAlpha(150),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Helper: PTT button color ──────────────────────────────────────────
  Color _getPTTColor() {
    switch (_voiceState) {
      case VoiceState.listening:
        return const Color(0xFFEF4444); // Red — recording
      case VoiceState.processing:
        return const Color(0xFFF59E0B); // Amber — processing
      case VoiceState.aiSpeaking:
        return const Color(0xFF10B981); // Green — AI speaking
      case VoiceState.idle:
        return const Color(0xFF6C63FF); // Purple — idle
    }
  }

  // ── Helper: PTT button icon ───────────────────────────────────────────
  IconData _getPTTIcon() {
    switch (_voiceState) {
      case VoiceState.listening:
        return Icons.mic;
      case VoiceState.processing:
        return Icons.hourglass_top;
      case VoiceState.aiSpeaking:
        return Icons.volume_up;
      case VoiceState.idle:
        return Icons.mic_none;
    }
  }

  // ── Helper: Status text color ─────────────────────────────────────────
  Color _getStatusColor(ColorScheme colorScheme) {
    switch (_voiceState) {
      case VoiceState.listening:
        return const Color(0xFFEF4444);
      case VoiceState.processing:
        return const Color(0xFFF59E0B);
      case VoiceState.aiSpeaking:
        return const Color(0xFF10B981);
      case VoiceState.idle:
        return colorScheme.onSurface.withAlpha(200);
    }
  }
}

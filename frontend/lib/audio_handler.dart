import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sound_stream/sound_stream.dart';

class AudioHandler {
  final AudioRecorder _recorder = AudioRecorder();
  final PlayerStream _player = PlayerStream();

  StreamSubscription<Uint8List>? _recordSub;

  bool _isPlayerInitialized = false;
  bool _isPlaying = false;

  // Jitter buffer properties
  final List<Uint8List> _jitterBuffer = [];
  bool _buffering = true;
  Timer? _playbackTimer;
  static const int _jitterDelayMs = 60; // Hold ~60ms of audio before starting playback

  /// Initialize the audio player for 24kHz Mono PCM streaming
  Future<void> initPlayer() async {
    if (_isPlayerInitialized) return;
    
    await _player.initialize(
      sampleRate: 24000,
      showLogs: false,
    );
    _isPlayerInitialized = true;
  }

  /// Start recording and yield a stream of raw 16kHz PCM bytes
  Future<Stream<Uint8List>?> startRecording() async {
    final hasMicPermission = await _recorder.hasPermission();
    if (!hasMicPermission) return null;

    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
          streamBufferSize: 2048,
        ),
      );
      return stream;
    } catch (e) {
      debugPrint('[AudioHandler] Error starting recording: $e');
      return null;
    }
  }

  /// Stop recording
  Future<void> stopRecording() async {
    await _recordSub?.cancel();
    _recordSub = null;
    await _recorder.stop();
  }

  /// Feed incoming PCM audio chunk from WebSocket into the jitter buffer
  Future<void> feedPlayback(Uint8List chunk) async {
    if (!_isPlayerInitialized) await initPlayer();

    _jitterBuffer.add(chunk);

    if (_buffering) {
      // If we are currently buffering, wait for the jitter delay before starting
      _playbackTimer ??= Timer(const Duration(milliseconds: _jitterDelayMs), () {
        _startJitterPlayback();
      });
    } else {
      // If we are already playing, feed it directly
      if (_isPlaying) {
        _player.writeChunk(chunk);
      }
    }
  }

  /// Start pulling from the jitter buffer and playing
  Future<void> _startJitterPlayback() async {
    _buffering = false;
    _playbackTimer?.cancel();
    _playbackTimer = null;

    if (!_isPlaying) {
      await _player.start();
      _isPlaying = true;
    }

    // Flush accumulated buffer
    for (var chunk in _jitterBuffer) {
      _player.writeChunk(chunk);
    }
    _jitterBuffer.clear();
  }

  /// Stop playback and clear buffers
  Future<void> stopPlayback() async {
    _buffering = true;
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _jitterBuffer.clear();

    if (_isPlaying) {
      try {
        await _player.stop();
      } catch (_) {}
      _isPlaying = false;
    }
  }

  /// Clean up resources
  Future<void> dispose() async {
    await stopRecording();
    await stopPlayback();
    await _recorder.dispose();
  }
}

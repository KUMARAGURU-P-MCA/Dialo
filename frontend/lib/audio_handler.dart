import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';

class AudioHandler {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _recordSub;

  bool _isPlayerInitialized = false;
  bool _isPlaying = false;
  Future<void>? _initFuture;
  DateTime? _playbackStartTime;

  final List<Uint8List> _jitterBuffer = [];
  bool _buffering = true;
  Timer? _playbackTimer;
  Timer? _drainTimer;

  static const int _jitterDelayMs = 120;
  static const double _msPerChunk = 42.67;
  static const int _drainSafetyMarginMs = 80;

  Function()? onPlaybackComplete;

  Future<void> initPlayer() {
    if (_isPlayerInitialized) return Future.value();
    _initFuture ??= _doInitPlayer();
    return _initFuture!;
  }

  Future<void> _doInitPlayer() async {
    try {
      await FlutterPcmSound.setup(
        sampleRate: 24000, 
        channelCount: 1,   
      );
      FlutterPcmSound.setFeedThreshold(8192);
      FlutterPcmSound.setFeedCallback(_onFeedRequest);
      _isPlayerInitialized = true;
    } finally {
      _initFuture = null;
    }
  }

  void _onFeedRequest(int remainingSamples) {}

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
      debugPrint('[AudioHandler] startRecording error: $e');
      return null;
    }
  }

  Future<void> stopRecording() async {
    await _recordSub?.cancel();
    _recordSub = null;
    await _recorder.stop();
  }

  Future<void> feedPlayback(Uint8List chunk) async {
    if (!_isPlayerInitialized) await initPlayer();

    _jitterBuffer.add(chunk);

    if (_buffering) {
      _playbackTimer ??= Timer(
        const Duration(milliseconds: _jitterDelayMs),
        _startJitterPlayback,
      );
    } else if (_isPlaying) {
      await _feedChunk(chunk);
    }
  }

  Future<void> _feedChunk(Uint8List bytes) async {
    try {
      final byteData = ByteData.sublistView(bytes);
      await FlutterPcmSound.feed(PcmArrayInt16(bytes: byteData));
    } catch (e) {
      debugPrint('[AudioHandler] feedChunk error: $e');
    }
  }

  Future<void> _startJitterPlayback() async {
    _buffering = false;
    _playbackTimer?.cancel();
    _playbackTimer = null;

    if (!_isPlaying) {
      await FlutterPcmSound.play();
      _isPlaying = true;
      _playbackStartTime = DateTime.now();
    }

    final buffered = List<Uint8List>.from(_jitterBuffer);
    _jitterBuffer.clear();
    for (final chunk in buffered) {
      await _feedChunk(chunk);
    }
  }

  void scheduleDrainCallback(int totalChunks) {
    _drainTimer?.cancel();

    // FIX: If Gemini didn't send any audio (instant release), unlock UI immediately
    if (totalChunks == 0) {
      debugPrint('[AudioHandler] No audio chunks received — resetting immediately');
      onPlaybackComplete?.call();
      return;
    }

    final int totalEstimatedMs = (totalChunks * _msPerChunk).ceil() + _drainSafetyMarginMs;
    int remainingMs = totalEstimatedMs;

    if (_playbackStartTime != null) {
      final elapsedMs = DateTime.now().difference(_playbackStartTime!).inMilliseconds;
      remainingMs = totalEstimatedMs - elapsedMs;
      if (remainingMs < 0) remainingMs = 0;
    }

    debugPrint(
      '[AudioHandler] Drain callback in ${remainingMs}ms '
      '(Total: ${totalEstimatedMs}ms, Elapsed: ${totalEstimatedMs - remainingMs}ms)',
    );

    if (remainingMs == 0) {
      debugPrint('[AudioHandler] Audio already finished — onPlaybackComplete immediately');
      onPlaybackComplete?.call();
    } else {
      _drainTimer = Timer(Duration(milliseconds: remainingMs), () {
        debugPrint('[AudioHandler] Drain complete — onPlaybackComplete');
        onPlaybackComplete?.call();
      });
    }
  }

  Future<void> stopPlayback() async {
    _drainTimer?.cancel();
    _drainTimer = null;
    _buffering = true;
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _playbackStartTime = null;
    _jitterBuffer.clear();

    if (_isPlaying) {
      try {
        await FlutterPcmSound.stop();
      } catch (_) {}
      _isPlaying = false;
    }
  }

  Future<void> dispose() async {
    await stopRecording();
    await stopPlayback();
    await _recorder.dispose();
    if (_isPlayerInitialized) {
      try {
        await FlutterPcmSound.release();
      } catch (_) {}
    }
  }
}
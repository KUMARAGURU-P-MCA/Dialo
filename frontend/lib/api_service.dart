import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ── Configuration ─────────────────────────────────────────────────────────────
// Change this to your server's actual IP/hostname
const String baseUrl = 'http://10.168.48.49:8000';

// ── Data Models ───────────────────────────────────────────────────────────────

class UserProfile {
  final String userId;
  final String name;
  final int currentLevel;
  final String baseLanguage;
  final int streakDays;

  UserProfile({
    required this.userId,
    required this.name,
    required this.currentLevel,
    required this.baseLanguage,
    required this.streakDays,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      userId: json['user_id'] as String,
      name: json['name'] as String,
      currentLevel: json['current_level'] as int,
      baseLanguage: json['base_language'] as String,
      streakDays: json['streak_days'] as int? ?? 0,
    );
  }
}

class SessionStartResult {
  final String sessionId;
  final int level;
  final String levelName;
  final String languageMode;
  final List<String> words;

  SessionStartResult({
    required this.sessionId,
    required this.level,
    required this.levelName,
    required this.languageMode,
    required this.words,
  });

  factory SessionStartResult.fromJson(Map<String, dynamic> json) {
    return SessionStartResult(
      sessionId: json['session_id'] as String,
      level: json['level'] as int,
      levelName: json['level_name'] as String,
      languageMode: json['language_mode'] as String,
      words: List<String>.from(json['words'] as List),
    );
  }
}

class LevelUpResult {
  final bool leveledUp;
  final int? newLevel;
  final int masteredCount;
  final double percent;
  final int currentLevel;
  final String levelName;

  LevelUpResult({
    required this.leveledUp,
    this.newLevel,
    required this.masteredCount,
    required this.percent,
    required this.currentLevel,
    required this.levelName,
  });

  factory LevelUpResult.fromJson(Map<String, dynamic> json) {
    return LevelUpResult(
      leveledUp: json['leveled_up'] as bool? ?? false,
      newLevel: json['new_level'] as int?,
      masteredCount: json['mastered_count'] as int? ?? 0,
      percent: (json['percent'] as num?)?.toDouble() ?? 0.0,
      currentLevel: json['current_level'] as int? ?? 1,
      levelName: json['level_name'] as String? ?? 'Beginner',
    );
  }
}

// ── API Service ───────────────────────────────────────────────────────────────

class ApiService {
  static const _headers = {'Content-Type': 'application/json'};

  // ── Create user (onboarding) ────────────────────────────────────────────
  static Future<UserProfile?> createUser({
    required String name,
    required String baseLanguage,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/users'),
        headers: _headers,
        body: jsonEncode({'name': name, 'base_language': baseLanguage}),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return UserProfile.fromJson(data['user'] as Map<String, dynamic>);
      }
      debugPrint('[API] createUser failed: ${res.statusCode} ${res.body}');
      return null;
    } catch (e) {
      debugPrint('[API] createUser error: $e');
      return null;
    }
  }

  // ── Get user profile ────────────────────────────────────────────────────
  static Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    try {
      final res = await http.get(Uri.parse('$baseUrl/users/$userId'));
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('[API] getUserProfile error: $e');
      return null;
    }
  }

  // ── Start session ───────────────────────────────────────────────────────
  static Future<SessionStartResult?> startSession(String userId) async {
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/session/start'),
        headers: _headers,
        body: jsonEncode({'user_id': userId}),
      );
      if (res.statusCode == 200) {
        return SessionStartResult.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>,
        );
      }
      debugPrint('[API] startSession failed: ${res.statusCode} ${res.body}');
      return null;
    } catch (e) {
      debugPrint('[API] startSession error: $e');
      return null;
    }
  }

  // ── End session ─────────────────────────────────────────────────────────
  static Future<bool> endSession({
    required String userId,
    required String sessionId,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/session/end'),
        headers: _headers,
        body: jsonEncode({'user_id': userId, 'session_id': sessionId}),
      );
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[API] endSession error: $e');
      return false;
    }
  }

  // ── Poll session result ─────────────────────────────────────────────────
  static Future<Map<String, dynamic>?> getSessionResult(String sessionId) async {
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/session/$sessionId/result'),
      );
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('[API] getSessionResult error: $e');
      return null;
    }
  }
}
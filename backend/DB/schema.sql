-- ═══════════════════════════════════════════════════════════════════════════
-- PTT Voice Agent — Supabase Schema
-- Run this in: Supabase Dashboard → SQL Editor → New Query
-- ═══════════════════════════════════════════════════════════════════════════

-- 1. USERS ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  user_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT NOT NULL,
  current_level  INTEGER DEFAULT 1 CHECK (current_level IN (1, 2, 3)),
  base_language  TEXT CHECK (base_language IN ('Tamil', 'English')),
  streak_days    INTEGER DEFAULT 0,
  created_at     TIMESTAMPTZ DEFAULT now()
);

-- 2. MASTER VOCABULARY ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS master_vocabulary (
  word_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  english_word       TEXT NOT NULL,
  tamil_meaning      TEXT,          -- used for Level 1 Tamil users
  simple_eng_meaning TEXT,          -- used for Level 1 English users
  level_required     INTEGER NOT NULL CHECK (level_required IN (1, 2, 3)),
  category           TEXT           -- e.g. 'phrasal_verb', 'idiom', 'conjunction'
);

-- 3. USER PROGRESS (spaced repetition) ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_progress (
  progress_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID REFERENCES users(user_id) ON DELETE CASCADE,
  word_id          UUID REFERENCES master_vocabulary(word_id) ON DELETE CASCADE,
  status           TEXT DEFAULT 'Learning' CHECK (status IN ('Learning', 'Mastered')),
  next_review_date DATE DEFAULT CURRENT_DATE,
  failure_count    INTEGER DEFAULT 0,
  last_reviewed_at TIMESTAMPTZ,
  UNIQUE(user_id, word_id)          -- one row per user per word
);

-- 4. SESSIONS ────────────────────────────────────────────────────────────────
-- room_name column intentionally omitted (not used in WebSocket architecture)
CREATE TABLE IF NOT EXISTS sessions (
  session_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES users(user_id) ON DELETE SET NULL,
  started_at    TIMESTAMPTZ DEFAULT now(),
  ended_at      TIMESTAMPTZ,
  duration_secs INTEGER,
  transcript    TEXT,
  words_tested  JSONB,             -- array of word_ids tested this session
  grader_json   JSONB,             -- raw grader output for audit
  grammar_score INTEGER CHECK (grammar_score BETWEEN 1 AND 10),
  status        TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'graded', 'failed'))
);

-- 5. WEEKLY INSIGHTS ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS weekly_insights (
  insight_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID REFERENCES users(user_id) ON DELETE CASCADE,
  generated_at       TIMESTAMPTZ DEFAULT now(),
  insight_text       TEXT,
  recommended_focus  JSONB,
  sessions_analysed  INTEGER
);

-- ── Indexes for common query patterns ────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_user_progress_user_id
  ON user_progress(user_id);

CREATE INDEX IF NOT EXISTS idx_user_progress_next_review
  ON user_progress(user_id, next_review_date)
  WHERE status = 'Learning';

CREATE INDEX IF NOT EXISTS idx_sessions_user_id
  ON sessions(user_id, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_master_vocab_level
  ON master_vocabulary(level_required);

-- ── Enable Row Level Security (RLS) ──────────────────────────────────────────
-- Your FastAPI server uses the service_role key which bypasses RLS.
-- Enable RLS to protect direct client access.
ALTER TABLE users            ENABLE ROW LEVEL SECURITY;
ALTER TABLE master_vocabulary ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_progress    ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekly_insights  ENABLE ROW LEVEL SECURITY;

-- ── Sample seed data for master_vocabulary (Level 1 — 5 examples) ────────────
-- You need 500+ Level 1 words, 1000+ Level 2, 1500+ Level 3 before launch.
-- Replace/extend this seed data with your full word bank.
INSERT INTO master_vocabulary (english_word, tamil_meaning, simple_eng_meaning, level_required, category) VALUES
  ('bought',        'வாங்கினேன்',    'past tense of buy — I bought a book',    1, 'verb'),
  ('look forward to','எதிர்பார்க்கிறேன்', 'to be excited about something future',  1, 'phrasal_verb'),
  ('nevertheless',  'இருப்பினும்',   'however; in spite of that',               1, 'conjunction'),
  ('apologise',     'மன்னிப்பு கேட்கிறேன்', 'to say sorry for something',       1, 'verb'),
  ('opportunity',   'வாய்ப்பு',      'a chance to do something',                1, 'noun'),
  ('negotiate',     'பேரம் பேசுகிறேன்', 'to discuss to reach an agreement',     2, 'verb'),
  ('consequently',  NULL,             'as a result; therefore',                  2, 'conjunction'),
  ('advocate',      NULL,             'to publicly support or recommend',        3, 'verb')
ON CONFLICT DO NOTHING;
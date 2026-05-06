"""
PTT AI Voice Agent — Backend Server with Supabase Integration
=============================================================
FastAPI WebSocket bridge between Flutter frontend and Google Gemini
Multimodal Live API (gemini-2.5-flash-native-audio-latest).
"""

import asyncio
import json
import logging
import os
import time
from datetime import date, datetime, timedelta

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from google import genai
from google.genai import types
from pydantic import BaseModel
from supabase import create_client, Client

# ── Load environment variables ───────────────────────────────────────────────
load_dotenv()

GEMINI_API_KEY   = os.getenv("GEMINI_API_KEY")
SUPABASE_URL     = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY")   # service_role key — NOT anon

if not GEMINI_API_KEY:
    raise RuntimeError("GEMINI_API_KEY not found in environment.")
if not SUPABASE_URL or not SUPABASE_SERVICE_KEY:
    raise RuntimeError("SUPABASE_URL and SUPABASE_SERVICE_KEY must be set in .env")

MODEL_ID = "gemini-2.5-flash-native-audio-latest"
GRADER_MODEL_ID = "gemini-2.5-flash"   

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s │ %(levelname)-5s │ %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("voice-agent")

# ── FastAPI app ──────────────────────────────────────────────────────────────
app = FastAPI(title="PTT Voice Agent with Supabase")

# ── Supabase client (singleton) ──────────────────────────────────────────────
supabase: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)

# ── Gemini client (singleton) ────────────────────────────────────────────────
gemini_client = genai.Client(api_key=GEMINI_API_KEY)

# ── Active sessions in memory {session_id: session_data} ────────────────────
active_sessions: dict = {}

# ════════════════════════════════════════════════════════════════════════════
# LEVEL & PROMPT CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════

LEVEL_THRESHOLDS = {
    1: {"name": "Beginner",     "max": 500,  "next": 2},
    2: {"name": "Intermediate", "max": 1500, "next": 3},
    3: {"name": "Pro",          "max": 9999, "next": None},
}

def build_system_prompt(level: int, base_language: str, word_list: list[dict]) -> str:
    if level == 1 and base_language == "Tamil":
        words_formatted = "\n".join(
            f"  - {w['english_word']}: {w['tamil_meaning']}" for w in word_list
        )
        return f"""You are an English teacher for Tamil-speaking beginners.
Explain all grammar rules strictly in Tamil.
Ask the user to translate Tamil sentences into English.
Test these 7 words today (show the Tamil meaning when introducing each word):
{words_formatted}
Session duration: 8 minutes. At 7 minutes say: "One minute left, let us summarise."
After each word practice, gently tell the user whether they used it correctly."""

    elif level == 1 and base_language == "English":
        words_formatted = "\n".join(
            f"  - {w['english_word']}: {w['simple_eng_meaning']}" for w in word_list
        )
        return f"""You are an English teacher for absolute beginners.
Speak very slowly in simple A1-level English only.
Ask the user to repeat sentences and fill in the blanks.
Test these 7 words today:
{words_formatted}
Session duration: 8 minutes. At 7 minutes say: "One minute left, let us summarise."
After each word practice, gently tell the user whether they used it correctly."""

    elif level == 2:
        words_formatted = "\n".join(f"  - {w['english_word']}" for w in word_list)
        return f"""You are a conversational English coach at B1-B2 level.
Speak only in English. Do not use any other language.
Use natural conversation speed. Gently correct errors mid-sentence.
Test these 7 words today:
{words_formatted}
Session duration: 8 minutes. At 7 minutes say: "One minute left, let us summarise."
After each word practice, tell the user clearly whether they used it correctly."""

    else:  # level == 3
        words_formatted = "\n".join(f"  - {w['english_word']}" for w in word_list)
        return f"""You are a strict native-English executive coach.
Do not use any language other than advanced English.
Challenge the user with complex sentence structures and idioms.
Hold them to a high standard. Correct every error precisely.
Test these 7 words today:
{words_formatted}
Session duration: 8 minutes. At 7 minutes say: "One minute left, let us summarise."
After each word practice, give precise feedback on correct or incorrect usage."""

# ════════════════════════════════════════════════════════════════════════════
# SUPABASE HELPERS
# ════════════════════════════════════════════════════════════════════════════

def get_user(user_id: str) -> dict:
    res = supabase.table("users").select("*").eq("user_id", user_id).single().execute()
    if not res.data:
        raise HTTPException(status_code=404, detail="User not found")
    return res.data

def get_due_words(user_id: str, level: int, count: int = 7) -> list[dict]:
    today = date.today().isoformat()

    due = (
        supabase.table("user_progress")
        .select("word_id, master_vocabulary(english_word, tamil_meaning, simple_eng_meaning)")
        .eq("user_id", user_id)
        .eq("status", "Learning")
        .lte("next_review_date", today)
        .limit(count)
        .execute()
    )
    words = [r["master_vocabulary"] for r in (due.data or []) if r.get("master_vocabulary")]

    if len(words) < count:
        needed = count - len(words)
        seen_word_ids = [r["word_id"] for r in (due.data or [])]

        new_words_query = (
            supabase.table("master_vocabulary")
            .select("word_id, english_word, tamil_meaning, simple_eng_meaning")
            .eq("level_required", level)
            .limit(needed + 20)
            .execute()
        )
        for w in (new_words_query.data or []):
            if len(words) >= count:
                break
            if w["word_id"] not in seen_word_ids:
                words.append(w)
                supabase.table("user_progress").insert({
                    "user_id": user_id,
                    "word_id": w["word_id"],
                    "status": "Learning",
                    "next_review_date": today,
                }).execute()

    return words[:count]

def update_streak(user_id: str):
    res = (
        supabase.table("sessions")
        .select("started_at")
        .eq("user_id", user_id)
        .eq("status", "graded")
        .order("started_at", desc=True)
        .limit(1)
        .execute()
    )
    user = get_user(user_id)
    today = date.today()

    if res.data:
        last_date = datetime.fromisoformat(res.data[0]["started_at"]).date()
        if last_date == today:
            return  
        elif last_date == today - timedelta(days=1):
            supabase.table("users").update(
                {"streak_days": user["streak_days"] + 1}
            ).eq("user_id", user_id).execute()
        else:
            supabase.table("users").update({"streak_days": 1}).eq("user_id", user_id).execute()
    else:
        supabase.table("users").update({"streak_days": 1}).eq("user_id", user_id).execute()

async def check_level_up(user_id: str) -> dict:
    res = (
        supabase.table("user_progress")
        .select("*", count="exact")
        .eq("user_id", user_id)
        .eq("status", "Mastered")
        .execute()
    )
    mastered = res.count or 0
    user = get_user(user_id)
    level = user["current_level"]
    threshold = LEVEL_THRESHOLDS[level]

    if mastered > threshold["max"] and threshold["next"]:
        new_level = threshold["next"]
        supabase.table("users").update(
            {"current_level": new_level}
        ).eq("user_id", user_id).execute()
        log.info(f"🎉 User {user_id} leveled up to Level {new_level}!")
        return {"leveled_up": True, "new_level": new_level, "mastered_count": mastered}

    prev_max = LEVEL_THRESHOLDS[level - 1]["max"] if level > 1 else 0
    progress_in_level = mastered - prev_max
    level_range = threshold["max"] - prev_max
    percent = round((progress_in_level / level_range) * 100, 1) if level_range > 0 else 100.0

    return {
        "leveled_up": False,
        "mastered_count": mastered,
        "percent": min(percent, 100.0),
        "current_level": level,
        "level_name": threshold["name"],
    }

async def grade_session(session_id: str, transcript: str, word_ids: list[str], user_id: str):
    try:
        log.info(f"📝 Grading session {session_id}...")

        words_res = (
            supabase.table("master_vocabulary")
            .select("word_id, english_word")
            .in_("word_id", word_ids)
            .execute()
        )
        words = {w["word_id"]: w["english_word"] for w in (words_res.data or [])}
        word_names = list(words.values())

        grading_prompt = f"""You are an English language grading assistant.
Analyze this conversation transcript and return ONLY a JSON object.

Words that were being tested: {json.dumps(word_names)}

Transcript:
{transcript}

Return this exact JSON structure (no markdown, no explanation):
{{
  "grammar_score": <integer 1-10>,
  "words_assessment": {{
    "<english_word>": {{"used": <true/false>, "correct": <true/false>}}
  }},
  "feedback_summary": "<2 sentence summary of performance>"
}}"""

        # ── NEW: Retry Logic for 503 (Busy) and 429 (Rate Limit) Errors ──
        max_retries = 3
        grader_response = None
        
        for attempt in range(max_retries):
            try:
                # Use the async client (.aio) so we don't block the WebSocket loop
                grader_response = await gemini_client.aio.models.generate_content(
                    model=GRADER_MODEL_ID,
                    contents=grading_prompt,
                )
                break  # Success! Break out of the retry loop
                
            except Exception as api_err:
                error_str = str(api_err)
                if "503" in error_str or "429" in error_str:
                    if attempt < max_retries - 1:
                        wait_time = (attempt + 1) * 3  # Wait 3s, then 6s
                        log.warning(f"⚠️ Gemini API busy (503/429). Retrying in {wait_time}s... (Attempt {attempt+1}/{max_retries})")
                        await asyncio.sleep(wait_time)
                    else:
                        raise api_err  # Out of retries, fail the grade
                else:
                    raise api_err  # Fail immediately on other types of errors (e.g., 400 Bad Request)
        # ─────────────────────────────────────────────────────────────────

        raw_json = grader_response.text.strip()
        if raw_json.startswith("```"):
            raw_json = raw_json.split("```")[1]
            if raw_json.startswith("json"):
                raw_json = raw_json[4:]
        grader_data = json.loads(raw_json.strip())

        grammar_score = grader_data.get("grammar_score", 5)
        words_assessment = grader_data.get("words_assessment", {})

        today = date.today().isoformat()
        for word_id, word_name in words.items():
            assessment = words_assessment.get(word_name, {})
            was_correct = assessment.get("correct", False)

            if was_correct:
                progress_res = (
                    supabase.table("user_progress")
                    .select("failure_count, status")
                    .eq("user_id", user_id)
                    .eq("word_id", word_id)
                    .single()
                    .execute()
                )
                p = progress_res.data or {}
                failures = p.get("failure_count", 0)
                intervals = [1, 3, 7, 14]
                interval_days = intervals[min(failures, len(intervals) - 1)] if failures == 0 else intervals[min(3 - failures, 0)]

                new_status = "Mastered" if failures == 0 else "Learning"
                next_review = (date.today() + timedelta(days=7)).isoformat()

                supabase.table("user_progress").update({
                    "status": new_status,
                    "next_review_date": next_review,
                    "last_reviewed_at": datetime.utcnow().isoformat(),
                }).eq("user_id", user_id).eq("word_id", word_id).execute()
            else:
                supabase.table("user_progress").update({
                    "next_review_date": (date.today() + timedelta(days=1)).isoformat(),
                    "last_reviewed_at": datetime.utcnow().isoformat(),
                    "failure_count": supabase.table("user_progress")
                        .select("failure_count")
                        .eq("user_id", user_id)
                        .eq("word_id", word_id)
                        .single()
                        .execute()
                        .data.get("failure_count", 0) + 1,
                }).eq("user_id", user_id).eq("word_id", word_id).execute()

        supabase.table("sessions").update({
            "grader_json": grader_data,
            "grammar_score": grammar_score,
            "status": "graded",
        }).eq("session_id", session_id).execute()

        log.info(f"✅ Session {session_id} graded — grammar score: {grammar_score}/10")

        update_streak(user_id)

        level_result = await check_level_up(user_id)
        if level_result["leveled_up"]:
            active_sessions[session_id] = active_sessions.get(session_id, {})
            active_sessions[session_id]["level_up_result"] = level_result

    except Exception as e:
        log.error(f"❌ Grading failed for session {session_id}: {e}")
        supabase.table("sessions").update(
            {"status": "failed"}
        ).eq("session_id", session_id).execute()

# ════════════════════════════════════════════════════════════════════════════
# REST ENDPOINTS
# ════════════════════════════════════════════════════════════════════════════

class SessionStartRequest(BaseModel):
    user_id: str

class SessionEndRequest(BaseModel):
    user_id: str
    session_id: str

class CreateUserRequest(BaseModel):
    name: str
    base_language: str  

@app.get("/health")
async def health():
    return {"status": "ok"}

@app.post("/users")
async def create_user(req: CreateUserRequest):
    if req.base_language not in ("Tamil", "English"):
        raise HTTPException(status_code=400, detail="base_language must be 'Tamil' or 'English'")

    res = supabase.table("users").insert({
        "name": req.name,
        "current_level": 1,
        "base_language": req.base_language,
        "streak_days": 0,
    }).execute()

    return {"user": res.data[0]}

@app.get("/users/{user_id}")
async def get_user_profile(user_id: str):
    user = get_user(user_id)
    level_info = await check_level_up(user_id)
    return {"user": user, "progress": level_info}

@app.post("/session/start")
async def start_session(req: SessionStartRequest):
    user = get_user(req.user_id)
    level = user["current_level"]
    base_language = user["base_language"]

    effective_language = base_language if level == 1 else "English"
    word_list = get_due_words(req.user_id, level, count=7)
    
    if not word_list:
        raise HTTPException(status_code=404, detail="No words available for this level. Please seed master_vocabulary.")

    system_prompt = build_system_prompt(level, effective_language, word_list)
    word_ids = [w["word_id"] for w in word_list if "word_id" in w]

    session_res = supabase.table("sessions").insert({
        "user_id": req.user_id,
        "started_at": datetime.utcnow().isoformat(),
        "words_tested": word_ids,
        "status": "pending",
    }).execute()

    session_id = session_res.data[0]["session_id"]

    active_sessions[session_id] = {
        "user_id": req.user_id,
        "level": level,
        "base_language": effective_language,
        "system_prompt": system_prompt,
        "word_ids": word_ids,
        "transcript_buffer": [],
    }

    log.info(f"📋 Session {session_id} created for user {req.user_id} (Level {level})")

    return {
        "session_id": session_id,
        "level": level,
        "level_name": LEVEL_THRESHOLDS[level]["name"],
        "language_mode": effective_language,
        "words": [w["english_word"] for w in word_list],
        "word_count": len(word_list),
    }

@app.post("/session/end")
async def end_session(req: SessionEndRequest):
    session_data = active_sessions.get(req.session_id)
    if not session_data:
        raise HTTPException(status_code=404, detail="Session not found or already ended")

    transcript = "\n".join(session_data.get("transcript_buffer", []))
    word_ids = session_data.get("word_ids", [])

    supabase.table("sessions").update({
        "ended_at": datetime.utcnow().isoformat(),
        "transcript": transcript,
    }).eq("session_id", req.session_id).execute()

    asyncio.create_task(
        grade_session(req.session_id, transcript, word_ids, req.user_id)
    )

    active_sessions.pop(req.session_id, None)
    log.info(f"🏁 Session {req.session_id} ended — grading queued")

    return {
        "status": "grading_queued",
        "message": "Session recorded. Grading will complete shortly.",
    }

@app.get("/session/{session_id}/result")
async def get_session_result(session_id: str):
    res = (
        supabase.table("sessions")
        .select("status, grammar_score, grader_json")
        .eq("session_id", session_id)
        .single()
        .execute()
    )
    if not res.data:
        raise HTTPException(status_code=404, detail="Session not found")
    return res.data

# ════════════════════════════════════════════════════════════════════════════
# WEBSOCKET ENDPOINT
# ════════════════════════════════════════════════════════════════════════════

@app.websocket("/ws/{session_id}")
async def websocket_endpoint(ws: WebSocket, session_id: str):
    await ws.accept()

    session_data = active_sessions.get(session_id)
    if not session_data:
        await ws.send_text(json.dumps({"error": "Invalid or expired session_id"}))
        await ws.close()
        return

    user_id = session_data["user_id"]
    system_prompt = session_data["system_prompt"]
    log.info(f"🔌 Flutter connected — session {session_id} (user {user_id})")

    live_config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=system_prompt,
        output_audio_transcription=types.AudioTranscriptionConfig(), 
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(
                disabled=True,
            ),
        ),
    )

    session_holder: dict         = {"session": None}
    turn_complete_time: dict     = {"ts": None}
    first_byte_logged: dict      = {"done": False}
    waiting_for_response: dict   = {"active": False}
    activity_started: dict       = {"active": False}
    pending_audio_chunks: dict   = {"count": 0}
    client_disconnected          = asyncio.Event()
    gemini_needs_reconnect       = asyncio.Event()

    async def flutter_to_gemini():
        try:
            while True:
                message = await ws.receive()

                if message["type"] == "websocket.receive":
                    gemini_session = session_holder["session"]
                    if gemini_session is None:
                        continue

                    if "bytes" in message and message["bytes"]:
                        audio_bytes = message["bytes"]
                        try:
                            if not activity_started["active"]:
                                await gemini_session.send_realtime_input(
                                    activity_start=types.ActivityStart()
                                )
                                activity_started["active"] = True
                                log.info("🎙️  ActivityStart sent")

                            await gemini_session.send_realtime_input(
                                media=types.Blob(
                                    data=audio_bytes,
                                    mime_type="audio/pcm;rate=16000",
                                )
                            )
                        except Exception as e:
                            log.warning(f"⚠️  Send to Gemini failed: {e}")
                            gemini_needs_reconnect.set()

                    elif "text" in message and message["text"]:
                        try:
                            data = json.loads(message["text"])
                            if data.get("action") == "turn_complete":
                                log.info("🎤 PTT turn_complete — signaling Gemini")
                                turn_complete_time["ts"]        = time.perf_counter()
                                first_byte_logged["done"]       = False
                                waiting_for_response["active"]  = True
                                pending_audio_chunks["count"]   = 0

                                try:
                                    if activity_started["active"]:
                                        await gemini_session.send_realtime_input(
                                            activity_end=types.ActivityEnd()
                                        )
                                        activity_started["active"] = False
                                        log.info("🛑 ActivityEnd sent")

                                    await gemini_session.send_realtime_input(
                                        audio_stream_end=True
                                    )
                                except Exception as e:
                                    log.warning(f"⚠️  turn_complete send failed: {e}")
                                    gemini_needs_reconnect.set()

                        except json.JSONDecodeError:
                            log.warning(f"⚠️  Non-JSON text: {message['text'][:100]}")

                elif message["type"] == "websocket.disconnect":
                    break

        except WebSocketDisconnect:
            log.info("🔌 Flutter disconnected")
        except Exception as e:
            log.error(f"❌ flutter_to_gemini error: {e}")
        finally:
            client_disconnected.set()

    async def gemini_to_flutter():
        try:
            while not client_disconnected.is_set():
                gemini_session = session_holder["session"]
                if gemini_session is None:
                    await asyncio.sleep(0.1)
                    continue

                try:
                    async for response in gemini_session.receive():
                        server_content = response.server_content
                        if server_content is None:
                            continue

                        model_turn = server_content.model_turn
                        if model_turn:
                            for part in model_turn.parts:
                                if part.text:
                                    if session_data:
                                        session_data["transcript_buffer"].append(
                                            f"AI: {part.text}"
                                        )

                                if part.inline_data and part.inline_data.data:
                                    audio_data = part.inline_data.data
                                    pending_audio_chunks["count"] += 1

                                    if (
                                        not first_byte_logged["done"]
                                        and turn_complete_time["ts"] is not None
                                    ):
                                        ttfb_ms = (
                                            time.perf_counter() - turn_complete_time["ts"]
                                        ) * 1000
                                        log.info(f"⚡ TTFB: {ttfb_ms:.0f}ms")
                                        first_byte_logged["done"] = True

                                    await ws.send_bytes(audio_data)

                        if hasattr(server_content, "output_transcription") and server_content.output_transcription:
                            text = server_content.output_transcription.text
                            if text and session_data:
                                session_data["transcript_buffer"].append(f"AI: {text}")

                        if server_content.turn_complete and waiting_for_response["active"]:
                            chunks = pending_audio_chunks["count"]
                            log.info(f"✅ Gemini turn complete ({chunks} chunks)")
                            waiting_for_response["active"] = False

                            await ws.send_text(json.dumps({
                                "event": "turn_complete",
                                "chunks": chunks,
                            }))

                except asyncio.CancelledError:
                    raise
                except Exception as e:
                    log.warning(f"⚠️  Gemini receive error (reconnecting): {e!r}")
                    gemini_needs_reconnect.set()
                    await asyncio.sleep(0.5)

        except asyncio.CancelledError:
            pass

    async def session_manager():
        while not client_disconnected.is_set():
            try:
                async with gemini_client.aio.live.connect(
                    model=MODEL_ID,
                    config=live_config,
                ) as gemini_session:
                    session_holder["session"] = gemini_session
                    log.info("🤖 Gemini Live session established")
                    gemini_needs_reconnect.clear()
                    activity_started["active"] = False

                    reconnect_task   = asyncio.create_task(gemini_needs_reconnect.wait())
                    disconnect_task  = asyncio.create_task(client_disconnected.wait())

                    done, pending = await asyncio.wait(
                        [reconnect_task, disconnect_task],
                        return_when=asyncio.FIRST_COMPLETED,
                    )
                    for t in pending:
                        t.cancel()
                        try:
                            await t
                        except asyncio.CancelledError:
                            pass

                    session_holder["session"] = None
                    if client_disconnected.is_set():
                        break
                    log.info("🔄 Gemini session expired — reconnecting...")

            except asyncio.CancelledError:
                break
            except Exception as e:
                log.error(f"❌ Gemini connect error: {e}")
                session_holder["session"] = None
                if client_disconnected.is_set():
                    break
                await asyncio.sleep(1)

    try:
        tasks = [
            asyncio.create_task(flutter_to_gemini()),
            asyncio.create_task(gemini_to_flutter()),
            asyncio.create_task(session_manager()),
        ]

        await client_disconnected.wait()

        for task in tasks:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    except Exception as e:
        log.error(f"❌ Unexpected error: {e}")
    finally:
        log.info(f"🔌 WebSocket cleanup complete for session {session_id}")

if __name__ == "__main__":
    import uvicorn
    log.info("🚀 Starting PTT Voice Agent server...")
    uvicorn.run("server:app", host="0.0.0.0", port=8000, log_level="info")
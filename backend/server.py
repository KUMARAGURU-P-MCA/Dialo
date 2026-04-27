"""
Direct Pipe PTT AI Voice Agent — Backend Server
=================================================
FastAPI WebSocket bridge between Flutter frontend and Google Gemini
Multimodal Live API (gemini-2.5-flash-native-audio-latest).

Audio Spec: 16kHz, 16-bit, Mono PCM (raw binary, no headers).

Architecture:
  Flutter <--raw PCM bytes--> FastAPI WS <--raw PCM bytes--> Gemini Live API

PTT Flow:
  1. Flutter streams raw PCM audio bytes while user holds the button.
  2. On release, Flutter sends JSON: {"action": "turn_complete"}
  3. Server intercepts the JSON, sends turn_complete signal to Gemini.
  4. Gemini responds with audio chunks, which are forwarded to Flutter.
"""

import asyncio
import json
import logging
import os
import time

from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from google import genai
from google.genai import types

# ── Load environment variables ──────────────────────────────────────────────
load_dotenv()

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
if not GEMINI_API_KEY:
    raise RuntimeError("GEMINI_API_KEY not found in environment. Set it in .env")

MODEL_ID = "gemini-2.5-flash-native-audio-latest"

# ── Logging setup ───────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s │ %(levelname)-5s │ %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("voice-agent")

# ── FastAPI app ─────────────────────────────────────────────────────────────
app = FastAPI(title="Direct Pipe PTT Voice Agent")

# ── Gemini client (singleton) ───────────────────────────────────────────────
gemini_client = genai.Client(api_key=GEMINI_API_KEY)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    """
    Main WebSocket endpoint. For each Flutter client connection:
    1. Opens a persistent Gemini Live session (auto-reconnects on timeout).
    2. Spawns two concurrent tasks:
       - flutter_to_gemini: reads from Flutter WS, forwards to Gemini.
       - gemini_to_flutter: reads from Gemini, forwards to Flutter WS.

    Gemini Live sessions have an idle timeout (~2 min). When the session
    expires, the server automatically spins up a new Gemini session so
    the Flutter client doesn't need to reconnect.
    """
    await ws.accept()
    log.info("🔌 Flutter client connected")

    # ── Gemini Live session configuration ───────────────────────────────────
    live_config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        # Disable automatic activity detection for PTT mode.
        # Gemini will only respond when we manually send audio_stream_end=True.
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(
                disabled=True,
            ),
        ),
    )

    # Shared mutable state accessible by both tasks
    session_holder: dict = {"session": None}
    turn_complete_time: dict = {"ts": None}
    first_byte_logged: dict = {"done": False}
    waiting_for_response: dict = {"active": False}
    activity_started: dict = {"active": False}  # Track if we sent ActivityStart
    client_disconnected = asyncio.Event()
    gemini_needs_reconnect = asyncio.Event()

    # ── Task 1: Flutter → Gemini ────────────────────────────────────────────
    async def flutter_to_gemini():
        """
        Read messages from Flutter WebSocket.
        - Binary frames: raw PCM audio → forward to Gemini.
        - Text frames: check for {"action": "turn_complete"}.
        """
        try:
            while True:
                message = await ws.receive()

                if message["type"] == "websocket.receive":
                    gemini_session = session_holder["session"]
                    if gemini_session is None:
                        # Session is reconnecting — drop this chunk silently
                        continue

                    # Binary audio data
                    if "bytes" in message and message["bytes"]:
                        audio_bytes = message["bytes"]
                        try:
                            # Send ActivityStart on the first audio chunk
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
                            log.warning(f"⚠️  Send to Gemini failed (session may be stale): {e}")
                            gemini_needs_reconnect.set()

                    # Text message (JSON command)
                    elif "text" in message and message["text"]:
                        text = message["text"]
                        try:
                            data = json.loads(text)
                            if data.get("action") == "turn_complete":
                                log.info(
                                    "🎤 PTT turn_complete received — "
                                    "signaling Gemini"
                                )
                                turn_complete_time["ts"] = time.perf_counter()
                                first_byte_logged["done"] = False
                                waiting_for_response["active"] = True

                                try:
                                    # Signal end of user activity
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
                            log.warning(
                                f"⚠️  Non-JSON text received: {text[:100]}"
                            )

                elif message["type"] == "websocket.disconnect":
                    log.info("🔌 Flutter client disconnected (receive loop)")
                    break

        except WebSocketDisconnect:
            log.info("🔌 Flutter client disconnected")
        except Exception as e:
            log.error(f"❌ flutter_to_gemini error: {e}")
        finally:
            client_disconnected.set()

    # ── Task 2: Gemini → Flutter ────────────────────────────────────────────
    async def gemini_to_flutter():
        """
        Read responses from Gemini Live session.
        Forward audio bytes to Flutter. Log TTFB.
        Auto-signals reconnect on session errors.
        """
        try:
            while not client_disconnected.is_set():
                gemini_session = session_holder["session"]
                if gemini_session is None:
                    # Wait a bit for session to be (re)established
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
                                if part.inline_data and part.inline_data.data:
                                    audio_data = part.inline_data.data

                                    # ── TTFB logging ────────────────────────
                                    if (
                                        not first_byte_logged["done"]
                                        and turn_complete_time["ts"] is not None
                                    ):
                                        ttfb_ms = (
                                            time.perf_counter()
                                            - turn_complete_time["ts"]
                                        ) * 1000
                                        log.info(
                                            f"⚡ TTFB: {ttfb_ms:.0f}ms "
                                            f"(first audio chunk from Gemini)"
                                        )
                                        first_byte_logged["done"] = True

                                    # Forward raw PCM bytes to Flutter
                                    await ws.send_bytes(audio_data)

                        # Log when Gemini finishes its turn (only once per interaction)
                        if server_content.turn_complete and waiting_for_response["active"]:
                            log.info("✅ Gemini turn complete — ready for next PTT")
                            waiting_for_response["active"] = False
                            await ws.send_text(
                                json.dumps({"event": "turn_complete"})
                            )

                except asyncio.CancelledError:
                    raise
                except Exception as e:
                    log.warning(f"⚠️  Gemini receive error (will reconnect): {e!r}")
                    gemini_needs_reconnect.set()
                    # Wait for reconnect to complete before looping
                    await asyncio.sleep(0.5)

        except asyncio.CancelledError:
            pass

    # ── Session manager: connects & auto-reconnects Gemini ──────────────────
    async def session_manager():
        """
        Manages the Gemini Live session lifecycle.
        Opens a session, and when it dies (idle timeout / error),
        automatically opens a new one.
        """
        while not client_disconnected.is_set():
            try:
                async with gemini_client.aio.live.connect(
                    model=MODEL_ID,
                    config=live_config,
                ) as gemini_session:
                    session_holder["session"] = gemini_session
                    log.info("🤖 Gemini Live session established")
                    gemini_needs_reconnect.clear()

                    # Wait until a reconnect is needed or client disconnects
                    reconnect_task = asyncio.create_task(gemini_needs_reconnect.wait())
                    disconnect_task = asyncio.create_task(client_disconnected.wait())

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
                        log.info("🔌 Client disconnected — stopping session manager")
                        break

                    log.info("🔄 Gemini session expired — reconnecting...")

            except asyncio.CancelledError:
                break
            except Exception as e:
                log.error(f"❌ Gemini session connect error: {e}")
                session_holder["session"] = None
                if client_disconnected.is_set():
                    break
                log.info("🔄 Retrying Gemini connection in 1s...")
                await asyncio.sleep(1)

    # ── Run all three tasks concurrently ────────────────────────────────────
    try:
        tasks = [
            asyncio.create_task(flutter_to_gemini()),
            asyncio.create_task(gemini_to_flutter()),
            asyncio.create_task(session_manager()),
        ]

        # Wait for client disconnect (flutter_to_gemini sets the event)
        await client_disconnected.wait()

        # Cancel all tasks
        for task in tasks:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    except Exception as e:
        log.error(f"❌ Unexpected error: {e}")
    finally:
        log.info("🔌 Session cleanup complete")


# ── Entry point ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn

    log.info("🚀 Starting Direct Pipe PTT Voice Agent server...")
    uvicorn.run(
        "server:app",
        host="0.0.0.0",
        port=8000,
        log_level="info",
    )

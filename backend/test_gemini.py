import asyncio
import os
from google import genai
from google.genai import types
from dotenv import load_dotenv

load_dotenv()
client = genai.Client()
MODEL_ID = "gemini-2.5-flash-native-audio-latest"

async def main():
    config = types.LiveConnectConfig(response_modalities=["AUDIO"])
    async with client.aio.live.connect(model=MODEL_ID, config=config) as session:
        print("Connected.")
        
        # Try sending an empty audio chunk with audio_stream_end?
        # Or try sending text.
        print("Sending audio_stream_end...")
        await session.send_realtime_input(audio_stream_end=True)
        
        print("Waiting for response...")
        async for response in session.receive():
            sc = response.server_content
            if sc:
                if sc.model_turn:
                    print("Got model turn parts:", len(sc.model_turn.parts))
                if sc.turn_complete:
                    print("Turn complete!")
                    break

asyncio.run(main())

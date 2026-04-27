import asyncio
import os
from google import genai
from google.genai import types
from dotenv import load_dotenv

load_dotenv()

async def main():
    client = genai.Client()
    config = types.LiveConnectConfig(response_modalities=["AUDIO"])
    async with client.aio.live.connect(model='gemini-2.5-flash-native-audio-latest', config=config) as session:
        print("Connected")
        await session.send_realtime_input(
            media=types.Blob(
                data=b'\x00' * 16000,
                mime_type="audio/pcm;rate=16000",
            )
        )
        await session.send_client_content(turn_complete=True)
        print("Sent end of turn")
        try:
            async for response in session.receive():
                print(f"Got response: turn_complete={response.server_content.turn_complete}")
        except Exception as e:
            print(f"Exception: {e}")
        print("Receive loop exited")

if __name__ == "__main__":
    asyncio.run(main())

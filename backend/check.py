import inspect
from google.genai.live import AsyncSession

print(inspect.signature(AsyncSession.send_realtime_input))

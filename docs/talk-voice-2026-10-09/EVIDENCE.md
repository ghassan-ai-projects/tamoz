# Talk with Tamoz by voice: evidence

## P0 provider smoke (2026-10-09, real calls, operator's `OPENROUTER_SPEECH_API_KEY`)

Input: a 3.55 s clip, "Check pond seven oxygen and tell me if aerator two is running.", made with macOS
`say -v Samantha` and converted to 16 kHz, 16-bit mono WAV (`afconvert`). The audio was sent as multipart
`file` (`audio/wav`) to `POST https://openrouter.ai/api/v1/audio/transcriptions`. Times are curl's
time to first byte from this machine.

| Model | Time to first byte | Transcript | Cost reported |
|---|---|---|---|
| `qwen/qwen3-asr-1.7b` (the owner's first choice) | 20.5 s, 17.4 s, 16.2 s, 22.6 s | exact (words for numbers) | $0.000027 |
| `qwen/qwen3-asr-flash-2026-02-10` | 2.8 s | exact (words) | $0.000105 |
| `qwen/qwen3-asr-0.6b` | 3.8 s | "pawn", "airator": wrong | $0.000012 |
| `openai/whisper-1` | 0.86 s | exact (digits) | $0.0004 |
| **`openai/gpt-4o-mini-transcribe`** (chosen, OD5 revised) | 0.78 s | exact (digits) | $0.00013 |
| `openai/gpt-4o-transcribe` | 1.1 s | exact (words) | $0.00025 |
| `mistralai/voxtral-mini-transcribe` | 0.36 s | exact (digits) | $0.00015 |

Speech output (`POST /api/v1/audio/speech`, `response_format: mp3`). The text was "Pond seven oxygen fell
from six point one to four point three since six this morning. Aerator two stopped at six ten." Each
result was checked with `ffprobe`, then transcribed back with `openai/gpt-4o-mini-transcribe`.

| Model (voice) | First byte / total | Container | Round trip |
|---|---|---|---|
| `openai/gpt-4o-mini-tts`, `…-2025-12-15` | 400 | — | "Model … does not exist": OpenRouter does not serve it now |
| **`hexgrad/kokoro-82m` (`af_heart`)** (chosen, OD2 revised) | 0.57 s / 0.84 s | mp3, 8.8 s | exact |
| `mistralai/voxtral-mini-tts-2603` (`en_paul_neutral`) | 0.49 s / 1.25 s | mp3, 6.3 s | exact |
| `elevenlabs/eleven-flash-v2.5` (`sarah`) | 0.37 s / 0.41 s | mp3, 7.0 s | "pH 7" for "Pond 7" |
| `deepgram/aura-2` (`aura-2-thalia-en`) | 0.47 s / 2.58 s | mp3, 7.9 s | exact |
| `x-ai/grok-voice-tts-1.0` (`eve`) | 0.42 s / 1.38 s | mp3, 8.0 s | exact |
| `microsoft/mai-voice-2-flash` | 1.16 s / 1.46 s | mp3, 7.7 s | — |
| `google/gemini-3.8-flash-tts` | 400 | — | "only supports response_format pcm" |

Conclusions:

- The multipart transcription request `EpisodeModelTransport#transcribe` already sends works unchanged on
  OpenRouter.
- WAV is accepted.
- OpenRouter's `/models?output_modalities=speech` lists the speech models (32 on this date). Each model
  has its own voice ids, so `TAMOZ_VOICE_NAME` is required whenever the model has no default voice.
- The owner chose `openai/gpt-4o-mini-transcribe` and `hexgrad/kokoro-82m` (`af_heart`) on 2026-10-09,
  after seeing these numbers. The samples are under `tmp/talk-p0/`, which is ignored by git.

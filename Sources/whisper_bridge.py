"""Local Whisper PCM bridge. Microphone audio is read only from stdin."""
import json
import sys

import numpy as np
import torch
import whisper

RATE = 16_000
WINDOW = RATE * 5

def emit(**fields):
    print(json.dumps(fields, ensure_ascii=False), flush=True)

def main():
    torch.set_num_threads(4)
    model = whisper.load_model(sys.argv[1], device="cpu")
    if not model.is_multilingual:
        raise RuntimeError("A multilingual model is required.")
    emit(ready=True)
    while raw := sys.stdin.buffer.read(WINDOW * 4):
        if len(raw) < RATE * 4 or len(raw) % 4:
            break
        pcm = np.frombuffer(raw, dtype="<f4").copy()
        if not np.all(np.isfinite(pcm)) or np.sqrt(np.mean(np.square(pcm))) < 0.002:
            continue
        result = model.transcribe(pcm, fp16=False, temperature=0,
                                  condition_on_previous_text=False, verbose=None)
        text = result["text"].strip()
        segments = result.get("segments") or []
        if text and any(s["no_speech_prob"] < 0.65 and s["avg_logprob"] > -1.3 for s in segments):
            emit(language=result["language"], text=text)

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit(error=str(error))
        raise SystemExit(1)

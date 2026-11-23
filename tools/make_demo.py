#!/usr/bin/env python3
"""Create a sample library of made-up recordings, to try the app without a pendant.

    runtime/venv/bin/python tools/make_demo.py
    open -a Pendant --args -libraryPath "$PWD/demo/Library" -transcriptionPaused YES

The audio is computer-generated speech (the macOS `say` command) reading the
made-up transcripts, encoded the same way the pendant's audio is. Nothing in
it is a real conversation. Your own library is not touched; the app goes back
to it the next time you open it normally.
"""
import ctypes.util
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

# Homebrew's libopus is not on the default search path for ctypes.
_find = ctypes.util.find_library
ctypes.util.find_library = lambda name: next(
    (p for p in ("/opt/homebrew/lib/libopus.dylib", "/usr/local/lib/libopus.dylib")
     if name == "opus" and os.path.exists(p)), None) or _find(name)

import opuslib  # noqa: E402
from pendant_client.cli import OggOpusWriter  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LIBRARY = ROOT / "demo" / "Library"
sys.path.insert(0, str(ROOT / "PendantApp" / "Support"))
import pendant_drain  # noqa: E402

EN, ES = "Samantha", "Paulina"

today = dt.date.today()
last_friday = today - dt.timedelta(days=(today.weekday() - 4) % 7 or 7)
last_monday = today - dt.timedelta(days=today.weekday() + 7)

# (day, time, title or None, [(voice, language, text, what the second model heard or None)])
RECORDINGS = [
    (last_monday, "09:05", "Weekly planning", [
        (EN, "en", "Good morning everyone. Let's start the weekly planning meeting.", None),
        (EN, "en", "First item, the new website should be ready for review by Thursday.", None),
        (EN, "en", "Second, the quarterly budget is due to finance on Friday.", None)]),
    (last_monday, "13:15", None, [
        (EN, "en", "Quick check in after lunch. The printer on the second floor is broken again.", None),
        (ES, "es", "Voy a llamar a mantenimiento esta tarde para que lo revisen.", None),
        (EN, "en", "Thanks. I'll print the handouts downstairs instead.", None)]),
    (last_monday, "15:40", "Client call notes", [
        (EN, "en", "Notes from the client call. They liked the first draft and asked for two changes.", None),
        (EN, "en", "Follow up in two weeks to see how it's going.", "Follow up into weeks to see how is going.")]),
    (last_friday, "08:30", "Team meeting", [
        (EN, "en", "Friday team meeting. Sign ups are up three percent from last month.", None),
        (EN, "en", "We need two volunteers for the help desk next Wednesday.", None),
        (ES, "es", "Yo puedo ayudar el miércoles, pero solo hasta las cuatro.", None)]),
    (last_friday, "11:10", None, [
        (EN, "en", "Review session for the launch checklist. Most questions were about the sign in page.", None),
        (EN, "en", "Remind everyone that the step by step guide is posted on the shared drive.", None)]),
    (last_friday, "15:05", "Reunión con proveedores", [
        (ES, "es", "Reunión con los proveedores. Hablamos de los plazos de entrega y de los precios.", None),
        (EN, "en", "They asked for the summary in both English and Spanish.", None),
        (ES, "es", "Les voy a mandar el resumen por correo el lunes.", None)]),
    (today, "08:00", None, [
        (EN, "en", "Morning stand up. Today's goal is to finish testing and write the release notes.", None),
        (EN, "en", "Second goal is to answer the open support questions.", None)]),
    (today, "10:15", "Budget review", [
        (EN, "en", "Budget review. The total request is four hundred and fifty dollars for supplies.",
         "Budget review. The total request is four hundred fifteen dollars for supplies."),
        (EN, "en", "Finance needs the signed form by the end of the day.", None),
        (ES, "es", "Perfecto, yo lo firmo y lo dejo en la oficina antes de las tres.", None)]),
    (today, "10:52", "Budget review, part two", [
        (EN, "en", "Back from the break. The form is signed and the order is placed.", None),
        (EN, "en", "Delivery is expected next Tuesday.", None)]),
    (today, "14:30", None, [
        (EN, "en", "End of day wrap up. Testing is done, the form is signed, and the printer is fixed.", None),
        (ES, "es", "Mañana empezamos con la siguiente fase del proyecto.", None),
        (EN, "en", "See everyone tomorrow.", None)]),
]


def clock(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 60}:{s % 60:02d}"


def speak(voice: str, text: str, tmp: Path) -> bytes:
    """Return 16 kHz mono 16-bit PCM of `text` spoken by a macOS voice."""
    subprocess.run(["say", "-v", voice, "-o", str(tmp / "p.aiff"), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                    str(tmp / "p.aiff"), str(tmp / "p.wav")], check=True)
    with wave.open(str(tmp / "p.wav"), "rb") as w:
        return w.readframes(w.getnframes())


def main() -> int:
    if LIBRARY.exists():
        shutil.rmtree(LIBRARY)
    tmp = Path(tempfile.mkdtemp())
    made = {}
    for day, hhmm, title, parts in RECORDINGS:
        folder = LIBRARY / "audio" / day.isoformat()
        folder.mkdir(parents=True, exist_ok=True)
        stem = hhmm.replace(":", "") + "00"
        pcm = b""
        lines = []
        t = 0.0
        for voice, lang, text, other in parts:
            audio = speak(voice, text, tmp)
            if other:
                lines += [f"[{clock(t)}] ({lang}) ⚠ models disagree, check by ear",
                          f"    Whisper:  {text}", f"    Parakeet: {other}"]
            else:
                lines.append(f"[{clock(t)}] ({lang}) {text}")
            pcm += audio + b"\0" * 32000          # one second of silence between sentences
            t += len(audio) / 32000 + 1.0

        encoder = opuslib.Encoder(16000, 1, "voip")
        writer = OggOpusWriter(folder / f"{stem}.opus")
        frame = 320 * 2                            # 20 ms of 16-bit samples
        for i in range(0, len(pcm) - frame + 1, frame):
            writer.add_packet(encoder.encode(pcm[i:i + frame], 320))
        writer.close()

        (folder / f"{stem}.txt").write_text("\n".join(lines))
        info = {"file": f"{stem}.opus", "start": f"{day.isoformat()}T{hhmm}:00",
                "seconds": round(t, 1), "time_uncertain": False, "demo": True}
        if title:
            info["title"] = title
        (folder / f"{stem}.json").write_text(json.dumps(info, indent=1))
        made[(day, hhmm)] = folder / f"{stem}.opus"
        print(f"{day}  {hhmm}  {t:5.1f} s  {title or ''}")

    # Join the two halves of today's budget review, to show a combined recording.
    class Args:
        out_dir = str(LIBRARY / "audio" / today.isoformat())
        title = "Budget review"
        inputs = [str(made[(today, "10:15")]), str(made[(today, "10:52")])]
    pendant_drain.cmd_combine(Args)
    for path in Args.inputs:
        for extra in (".opus", ".json", ".txt"):
            Path(path).with_suffix(extra).unlink(missing_ok=True)

    shutil.rmtree(tmp, ignore_errors=True)
    print(f"\nSample library written to {LIBRARY}")
    print(f'Open it with:  open -a Pendant --args -libraryPath "{LIBRARY}" -transcriptionPaused YES')
    return 0


if __name__ == "__main__":
    sys.exit(main())

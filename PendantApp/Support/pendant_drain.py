#!/usr/bin/env python3
"""Drain a Limitless Pendant into the Pendant app's library, then stop.

Differences from `pendant sync` (pendant-cli), which this builds on:

* Crash-safe: every message is appended to a journal file on disk as it
  arrives. pendant-cli acks (deletes) each page on the pendant as it is
  received, so the Mac copy must never live only in memory.
* Stops by itself: a pendant that is recording never goes idle, so we stop
  once we receive a page that was sealed after this sync began (we have
  caught up), as well as on idle or a time limit.
* Own recording boundaries: audio is joined into one recording while it is
  continuous, judged by the pendant's uptime (immune to its clock being
  reset) and falling back to wall-clock time.

Progress is printed as one JSON object per line for the app to read.

Usage:
    pendant_drain.py sync --address ADDR --library DIR
    pendant_drain.py scan
    pendant_drain.py recover --library DIR      # decode leftover journals
    pendant_drain.py combine --out-dir DIR [--title T] A.opus B.opus ...
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import json
import os
import signal
import struct
import sys
import time
from pathlib import Path

GAP_MS = 30_000            # audio further apart than this starts a new recording
PLAUSIBLE_MS = 1_600_000_000_000  # timestamps below this mean "clock not set"
MIN_SECONDS = 1.0          # drop blips shorter than this
KEEP_RAW_DAYS = 14         # raw journals are deleted after this many days
FRAME_MS = 20              # one Opus packet from the pendant is 20 ms


def emit(event: str, **fields) -> None:
    print(json.dumps({"event": event, **fields}), flush=True)


# --------------------------------------------------------------------------
# Journal: [4-byte little-endian length][message bytes] repeated.
# --------------------------------------------------------------------------

def journal_append(fp, payload: bytes) -> None:
    fp.write(struct.pack("<I", len(payload)))
    fp.write(payload)
    fp.flush()


def journal_read(path: Path):
    data = path.read_bytes()
    pos = 0
    while pos + 4 <= len(data):
        (n,) = struct.unpack_from("<I", data, pos)
        pos += 4
        if pos + n > len(data):
            break  # truncated final record (crash mid-write); drop it
        yield data[pos:pos + n]
        pos += n


# --------------------------------------------------------------------------
# Decode a journal into recordings in the library.
# --------------------------------------------------------------------------

class _Rec:
    def __init__(self, tmp_path: Path):
        from pendant_client.cli import OggOpusWriter
        self.tmp_path = tmp_path
        self.writer = OggOpusWriter(tmp_path)
        self.chunks = 0
        self.first_ts = 0
        self.last_ts = 0
        self.pages: set[int] = set()

    def add(self, chunk) -> None:
        self.writer.add_packet(chunk.opus)
        self.chunks += 1
        ts = chunk.absolute_timestamp_ms
        if self.first_ts == 0:
            self.first_ts = ts
        self.last_ts = ts
        self.pages.add(chunk.page_index)

    @property
    def seconds(self) -> float:
        return self.chunks * FRAME_MS / 1000


def decode_journal(journal: Path, library: Path) -> list[dict]:
    """Split a journal into recordings and file them under library/audio/DATE/."""
    from pendant_client.decode import iter_audio_chunks_from_messages

    tmp_dir = library / "raw" / (journal.stem + ".tmp")
    tmp_dir.mkdir(parents=True, exist_ok=True)

    recs: list[_Rec] = []
    cur: _Rec | None = None
    prev_uptime = None
    prev_ts = None

    for chunk in iter_audio_chunks_from_messages(journal_read(journal)):
        if not chunk.opus:
            continue
        uptime = chunk.boot_uptime_ms
        ts = chunk.absolute_timestamp_ms
        contiguous = False
        if cur is not None:
            if prev_uptime is not None and 0 <= uptime - prev_uptime <= GAP_MS:
                contiguous = True       # same boot, no long pause
            elif prev_ts is not None and 0 <= ts - prev_ts <= GAP_MS:
                contiguous = True       # rebooted, but wall clock is continuous
        if not contiguous:
            cur = _Rec(tmp_dir / f"rec{len(recs):04d}.opus")
            recs.append(cur)
        cur.add(chunk)
        prev_uptime, prev_ts = uptime, ts

    results: list[dict] = []
    for rec in recs:
        rec.writer.close()
        if rec.seconds < MIN_SECONDS:
            rec.tmp_path.unlink(missing_ok=True)
            continue

        # Work out the start time. The pendant's clock can be stale at the
        # start of a recording (it is corrected when a sync connects), so
        # trust the last timestamp and count back from it.
        uncertain = False
        if rec.last_ts > PLAUSIBLE_MS:
            start_ms = rec.last_ts - int(rec.seconds * 1000)
        elif rec.first_ts > PLAUSIBLE_MS:
            start_ms = rec.first_ts
        else:
            start_ms = int(time.time() * 1000)
            uncertain = True
        start = dt.datetime.fromtimestamp(start_ms / 1000)

        day_dir = library / "audio" / f"{start:%Y-%m-%d}"
        day_dir.mkdir(parents=True, exist_ok=True)
        stem = f"{start:%H%M%S}"
        dest = day_dir / f"{stem}.opus"
        n = 1
        while dest.exists():
            n += 1
            dest = day_dir / f"{stem}-{n}.opus"
        os.replace(rec.tmp_path, dest)

        info = {
            "file": dest.name,
            "start": start.isoformat(timespec="seconds"),
            "seconds": round(rec.seconds, 1),
            "time_uncertain": uncertain,
            "pages": [min(rec.pages), max(rec.pages)],
            "source_journal": journal.name,
        }
        dest.with_suffix(".json").write_text(json.dumps(info, indent=1))
        results.append({**info, "path": str(dest)})

    try:
        tmp_dir.rmdir()
    except OSError:
        pass
    # Mark the journal as decoded so `recover` skips it.
    journal.with_suffix(".done").write_text(dt.datetime.now().isoformat(timespec="seconds"))
    return results


def cleanup_raw(library: Path) -> None:
    cutoff = time.time() - KEEP_RAW_DAYS * 86400
    for j in (library / "raw").glob("*.journal"):
        if j.with_suffix(".done").exists() and j.stat().st_mtime < cutoff:
            j.unlink(missing_ok=True)
            j.with_suffix(".done").unlink(missing_ok=True)


def recover(library: Path) -> list[dict]:
    """Decode journals left behind by a sync that crashed before decoding."""
    out: list[dict] = []
    raw = library / "raw"
    if not raw.exists():
        return out
    for j in sorted(raw.glob("*.journal")):
        if not j.with_suffix(".done").exists() and j.stat().st_size > 0:
            emit("recovering", journal=j.name)
            out.extend(decode_journal(j, library))
    return out


# --------------------------------------------------------------------------
# Sync
# --------------------------------------------------------------------------

async def capture(address: str, journal: Path, max_seconds: float, idle: float) -> dict:
    from pendant_client.decode import iter_audio_chunks_from_messages
    from pendant_client.session import PendantSession

    stats = {"messages": 0, "bytes": 0, "stop_reason": "idle"}
    stop_requested = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_requested.set)

    async with PendantSession(address) as s:
        await s.handshake()  # sets the pendant's clock to this Mac's time
        sync_started_ms = int(time.time() * 1000)
        di = await s.get_device_info()
        emit("connected", firmware=di.firmware_ver, battery=di.battery_percent)

        deadline = time.time() + max_seconds
        last_progress = 0.0
        with journal.open("ab") as fp:
            gen = s.download_raw_pendant_messages(idle_timeout=idle)
            try:
                pending_stop = None
                async for payload in gen:
                    # pendant-cli acks (deletes) a page only when we ask for
                    # the next message. So a stop decided on one message is
                    # acted on here: the page that triggered it has now been
                    # acked, and this new message is left on the pendant
                    # (not journaled, not acked) for the next sync.
                    if pending_stop:
                        stats["stop_reason"] = pending_stop
                        break
                    journal_append(fp, payload)
                    stats["messages"] += 1
                    stats["bytes"] += len(payload)

                    newest_ts = 0
                    for chunk in iter_audio_chunks_from_messages([payload]):
                        newest_ts = max(newest_ts, chunk.absolute_timestamp_ms)

                    now = time.time()
                    if now - last_progress > 1.0:
                        last_progress = now
                        emit("progress", messages=stats["messages"], bytes=stats["bytes"])

                    if newest_ts >= sync_started_ms:
                        pending_stop = "caught_up"
                    elif stop_requested.is_set():
                        pending_stop = "stopped"
                    elif now > deadline:
                        pending_stop = "time_limit"
            finally:
                await gen.aclose()
                os.fsync(fp.fileno())
    return stats


def cmd_sync(args) -> int:
    library = Path(args.library).expanduser()
    (library / "raw").mkdir(parents=True, exist_ok=True)

    recovered = recover(library)

    journal = library / "raw" / f"{dt.datetime.now():%Y%m%d-%H%M%S}.journal"
    try:
        stats = asyncio.run(capture(args.address, journal, args.max_seconds, args.idle))
    except Exception as e:  # noqa: BLE001 - report every failure to the app
        # Whatever reached the journal is still decoded below.
        emit("error", message=f"{type(e).__name__}: {e}")
        stats = {"messages": 0, "bytes": 0, "stop_reason": "error"}

    recordings: list[dict] = list(recovered)
    if journal.exists() and journal.stat().st_size > 0:
        recordings.extend(decode_journal(journal, library))
    elif journal.exists():
        journal.unlink()
    cleanup_raw(library)

    emit("done", recordings=recordings, **stats)
    return 0 if stats["stop_reason"] != "error" else 1


def cmd_scan(args) -> int:
    from pendant_client.session import find_pendant
    addr = asyncio.run(find_pendant(timeout=args.timeout))
    if addr is None:
        emit("error", message="No pendant found. Is it charged and nearby?")
        return 2
    emit("found", address=addr)
    return 0


def cmd_recover(args) -> int:
    library = Path(args.library).expanduser()
    emit("done", recordings=recover(library), messages=0, bytes=0, stop_reason="recover")
    return 0


# --------------------------------------------------------------------------
# Combine recordings: joins the audio without re-encoding it, and joins the
# transcripts with their timestamps shifted to match.
# --------------------------------------------------------------------------

def ogg_packets(path: Path):
    """Yield the Opus audio packets of an Ogg Opus file (headers skipped)."""
    data = path.read_bytes()
    pos = 0
    packet = b""
    index = 0
    while pos + 27 <= len(data) and data[pos:pos + 4] == b"OggS":
        nsegs = data[pos + 26]
        table = data[pos + 27:pos + 27 + nsegs]
        body = pos + 27 + nsegs
        for seg in table:
            packet += data[body:body + seg]
            body += seg
            if seg < 255:           # a segment shorter than 255 ends the packet
                if index >= 2 and packet:   # packets 0 and 1 are OpusHead and OpusTags
                    yield packet
                index += 1
                packet = b""
        pos = body


_STAMP = __import__("re").compile(r"^\[(\d+):(\d{2})(?::(\d{2}))?\]")


def shift_transcript(text: str, offset: float) -> str:
    """Add `offset` seconds to every [m:ss] timestamp at the start of a line."""
    def clock(seconds: float) -> str:
        t = int(seconds)
        return f"{t // 3600}:{t % 3600 // 60:02d}:{t % 60:02d}" if t >= 3600 else f"{t // 60}:{t % 60:02d}"

    out = []
    for line in text.splitlines():
        m = _STAMP.match(line)
        if m:
            a, b, c = m.group(1), m.group(2), m.group(3)
            secs = int(a) * 3600 + int(b) * 60 + int(c) if c else int(a) * 60 + int(b)
            line = f"[{clock(secs + offset)}]" + line[m.end():]
        out.append(line)
    return "\n".join(out)


def cmd_combine(args) -> int:
    from pendant_client.cli import OggOpusWriter

    inputs = [Path(p) for p in args.inputs]
    if len(inputs) < 2:
        emit("error", message="Pick at least two recordings to combine.")
        return 1
    if any(p.suffix.lower() != ".opus" for p in inputs):
        emit("error", message="Only pendant recordings (.opus) can be combined.")
        return 1

    sides = []
    for p in inputs:
        try:
            sides.append(json.loads(p.with_suffix(".json").read_text()))
        except Exception:  # noqa: BLE001
            emit("error", message=f"Missing details file for {p.name}.")
            return 1
    order = sorted(range(len(inputs)), key=lambda i: sides[i]["start"])
    inputs = [inputs[i] for i in order]
    sides = [sides[i] for i in order]

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = inputs[0].stem.split("-")[0] + "-combined"
    dest = out_dir / f"{stem}.opus"
    n = 1
    while dest.exists():
        n += 1
        dest = out_dir / f"{stem}-{n}.opus"

    writer = OggOpusWriter(dest)
    offsets = []
    total_packets = 0
    for p in inputs:
        offsets.append(total_packets * FRAME_MS / 1000)
        for packet in ogg_packets(p):
            writer.add_packet(packet)
            total_packets += 1
    writer.close()
    seconds = total_packets * FRAME_MS / 1000

    # Transcripts: only joined when every part has one. Otherwise the combined
    # recording is left without one and the app transcribes it as a whole.
    texts = [p.with_suffix(".txt") for p in inputs]
    if all(t.exists() for t in texts):
        parts = []
        for p, side, t, off in zip(inputs, sides, texts, offsets):
            when = dt.datetime.fromisoformat(side["start"]).strftime("%-I:%M %p")
            label = side.get("title") or f"recording from {when}"
            parts.append(f"({label})\n" + shift_transcript(t.read_text(), off))
        dest.with_suffix(".txt").write_text("\n\n".join(parts))

        pieces = []
        for p, off in zip(inputs, offsets):
            tj = p.with_name(p.stem + ".transcript.json")
            if tj.exists():
                for piece in json.loads(tj.read_text()).get("pieces", []):
                    piece["start"] += off
                    piece["end"] += off
                    pieces.append(piece)
        if pieces:
            dest.with_name(dest.stem + ".transcript.json").write_text(
                json.dumps({"audio": dest.name, "seconds": seconds, "pieces": pieces,
                            "combined_from": [p.name for p in inputs]}, indent=1))

    # Where each part begins in the combined audio (seconds), so the app can
    # mark the joins on the playback bar. Parts that were themselves combined
    # earlier keep their own joins.
    joins = []
    for side, off in zip(sides, offsets):
        if off > 0:
            joins.append(round(off, 2))
        joins.extend(round(off + j, 2) for j in side.get("joins", []))

    info = {
        "file": dest.name,
        "start": sides[0]["start"],
        "joins": sorted(joins),
        "seconds": round(seconds, 1),
        "time_uncertain": any(s.get("time_uncertain") for s in sides),
        "combined_from": [p.name for p in inputs],
    }
    title = args.title.strip() if args.title else ""
    if title:
        info["title"] = title
    if any(s.get("demo") for s in sides):
        info["demo"] = True
    dest.with_suffix(".json").write_text(json.dumps(info, indent=1))
    emit("combined", path=str(dest), seconds=info["seconds"], parts=len(inputs))
    return 0


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("sync")
    sp.add_argument("--address", required=True)
    sp.add_argument("--library", required=True)
    sp.add_argument("--max-seconds", type=float, default=4 * 3600)
    sp.add_argument("--idle", type=float, default=5.0)
    sp.set_defaults(fn=cmd_sync)

    sc = sub.add_parser("scan")
    sc.add_argument("--timeout", type=float, default=15.0)
    sc.set_defaults(fn=cmd_scan)

    sr = sub.add_parser("recover")
    sr.add_argument("--library", required=True)
    sr.set_defaults(fn=cmd_recover)

    sm = sub.add_parser("combine")
    sm.add_argument("--out-dir", required=True)
    sm.add_argument("--title", default="")
    sm.add_argument("inputs", nargs="+")
    sm.set_defaults(fn=cmd_combine)

    args = p.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())

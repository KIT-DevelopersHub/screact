#!/usr/bin/env python3
"""Render YubiBoard hand-frame JSONL as an MP4 on a black background.

This debug tool intentionally uses only the Python standard library. FFmpeg is
invoked as a subprocess so the Android project does not gain a Python package
dependency.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable, Sequence


HAND_CONNECTIONS: tuple[tuple[int, int], ...] = (
    (0, 1),
    (1, 2),
    (2, 3),
    (3, 4),
    (0, 5),
    (5, 6),
    (6, 7),
    (7, 8),
    (5, 9),
    (9, 10),
    (10, 11),
    (11, 12),
    (9, 13),
    (13, 14),
    (14, 15),
    (15, 16),
    (13, 17),
    (17, 18),
    (18, 19),
    (19, 20),
    (0, 17),
)
FINGERTIPS = frozenset((4, 8, 12, 16, 20))
TRACK_COLORS = ((59, 220, 182), (255, 145, 82))


@dataclass(frozen=True)
class LoggedHand:
    track_id: int
    landmarks: tuple[tuple[float, float, float], ...]


@dataclass(frozen=True)
class LoggedFrame:
    frame_id: int
    session_id: str
    captured_at_ms: int | None
    received_at_seconds: float | None
    hands: tuple[LoggedHand, ...]

    @property
    def detected(self) -> bool:
        return bool(self.hands)

    @property
    def landmarks(self) -> tuple[tuple[float, float, float], ...]:
        return self.hands[0].landmarks if self.hands else ()


def _parse_received_at(value: Any) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def parse_logged_frame(value: Any) -> LoggedFrame | None:
    """Parse one raw hand_frame or mock-server hand-frames.jsonl entry."""
    if not isinstance(value, dict):
        return None
    message = value.get("message", value)
    if not isinstance(message, dict) or message.get("messageType") != "hand_frame":
        return None
    raw_hands = message.get("hands")
    if raw_hands is None:
        legacy = message.get("hand")
        if not isinstance(legacy, dict) or not isinstance(legacy.get("detected"), bool):
            return None
        raw_hands = [dict(legacy, trackId=1)] if legacy["detected"] else []
    if not isinstance(raw_hands, list) or len(raw_hands) > 2:
        return None

    parsed_hands: list[LoggedHand] = []
    seen_ids: set[int] = set()
    for hand in raw_hands:
        if not isinstance(hand, dict):
            return None
        track_id = hand.get("trackId")
        if not isinstance(track_id, int) or track_id <= 0 or track_id in seen_ids:
            return None
        seen_ids.add(track_id)
        landmarks = hand.get("landmarks")
        if not isinstance(landmarks, list) or len(landmarks) != 21:
            return None
        parsed_landmarks: list[tuple[float, float, float]] = []
        for point in landmarks:
            if not isinstance(point, list) or len(point) != 3:
                return None
            try:
                coordinates = tuple(float(coordinate) for coordinate in point)
            except (TypeError, ValueError):
                return None
            if not all(math.isfinite(coordinate) for coordinate in coordinates):
                return None
            parsed_landmarks.append(coordinates)
        parsed_hands.append(LoggedHand(track_id, tuple(parsed_landmarks)))

    captured = message.get("capturedAtMonotonicMs")
    try:
        captured_at_ms = int(captured) if captured is not None else None
    except (TypeError, ValueError):
        captured_at_ms = None

    try:
        frame_id = int(message.get("frameId", 0))
    except (TypeError, ValueError):
        frame_id = 0

    return LoggedFrame(
        frame_id=frame_id,
        session_id=str(message.get("sessionId", "")),
        captured_at_ms=captured_at_ms,
        received_at_seconds=_parse_received_at(value.get("receivedAtUtc")),
        hands=tuple(sorted(parsed_hands, key=lambda hand: hand.track_id)),
    )


def load_frames(path: Path) -> tuple[list[LoggedFrame], int]:
    frames: list[LoggedFrame] = []
    skipped = 0
    with path.open("r", encoding="utf-8-sig") as source:
        for line in source:
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            frame = parse_logged_frame(value)
            if frame is None:
                skipped += 1
            else:
                frames.append(frame)
    return frames, skipped


def build_timeline(
    frames: Sequence[LoggedFrame], fps: int, max_gap_ms: int
) -> list[LoggedFrame]:
    """Resample source frames to a stable FPS and cap reconnect/idle gaps."""
    if not frames:
        return []

    nominal_step = 1.0 / fps
    timeline_seconds = [0.0]
    for previous, current in zip(frames, frames[1:]):
        delta: float | None = None
        if (
            previous.session_id == current.session_id
            and previous.captured_at_ms is not None
            and current.captured_at_ms is not None
        ):
            delta = (current.captured_at_ms - previous.captured_at_ms) / 1000.0
        elif (
            previous.received_at_seconds is not None
            and current.received_at_seconds is not None
        ):
            delta = current.received_at_seconds - previous.received_at_seconds
        if delta is None or delta <= 0:
            delta = nominal_step
        delta = min(delta, max_gap_ms / 1000.0)
        timeline_seconds.append(timeline_seconds[-1] + delta)

    duration = timeline_seconds[-1] + nominal_step
    output_count = max(1, math.ceil(duration * fps - 1e-9))
    output: list[LoggedFrame] = []
    source_index = 0
    for output_index in range(output_count):
        output_time = output_index / fps
        while (
            source_index + 1 < len(frames)
            and timeline_seconds[source_index + 1] <= output_time + 1e-9
        ):
            source_index += 1
        output.append(frames[source_index])
    return output


def _paint_circle(
    pixels: bytearray,
    width: int,
    height: int,
    center_x: int,
    center_y: int,
    radius: int,
    color: tuple[int, int, int],
) -> None:
    radius_squared = radius * radius
    for y in range(max(0, center_y - radius), min(height, center_y + radius + 1)):
        dy_squared = (y - center_y) ** 2
        for x in range(max(0, center_x - radius), min(width, center_x + radius + 1)):
            if (x - center_x) ** 2 + dy_squared <= radius_squared:
                offset = (y * width + x) * 3
                pixels[offset : offset + 3] = bytes(color)


def _paint_line(
    pixels: bytearray,
    width: int,
    height: int,
    start: tuple[int, int],
    end: tuple[int, int],
    thickness: int,
    color: tuple[int, int, int],
) -> None:
    x0, y0 = start
    x1, y1 = end
    dx = abs(x1 - x0)
    sx = 1 if x0 < x1 else -1
    dy = -abs(y1 - y0)
    sy = 1 if y0 < y1 else -1
    error = dx + dy
    radius = max(1, thickness // 2)
    while True:
        _paint_circle(pixels, width, height, x0, y0, radius, color)
        if x0 == x1 and y0 == y1:
            break
        doubled = 2 * error
        if doubled >= dy:
            error += dy
            x0 += sx
        if doubled <= dx:
            error += dx
            y0 += sy


def render_rgb_frame(frame: LoggedFrame, width: int, height: int) -> bytes:
    pixels = bytearray(width * height * 3)
    line_width = max(2, round(min(width, height) / 180))
    point_radius = max(3, round(min(width, height) / 100))
    for hand_index, hand in enumerate(frame.hands):
        color = TRACK_COLORS[hand_index % len(TRACK_COLORS)]
        points = [
            (
                round(min(1.0, max(0.0, x)) * (width - 1)),
                round(min(1.0, max(0.0, y)) * (height - 1)),
            )
            for x, y, _ in hand.landmarks
        ]
        for start_index, end_index in HAND_CONNECTIONS:
            _paint_line(
                pixels, width, height, points[start_index], points[end_index],
                line_width, color,
            )
        for index, (x, y) in enumerate(points):
            radius = point_radius + 1 if index in FINGERTIPS else point_radius
            _paint_circle(pixels, width, height, x, y, radius, color)
    return bytes(pixels)


def render_video(
    frames: Iterable[LoggedFrame],
    output_path: Path,
    width: int,
    height: int,
    fps: int,
    ffmpeg: str,
) -> int:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "rawvideo",
        "-pixel_format",
        "rgb24",
        "-video_size",
        f"{width}x{height}",
        "-framerate",
        str(fps),
        "-i",
        "-",
        "-an",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(output_path),
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    assert process.stdin is not None
    count = 0
    try:
        for frame in frames:
            process.stdin.write(render_rgb_frame(frame, width, height))
            count += 1
    except (BrokenPipeError, OSError):
        pass
    finally:
        process.stdin.close()
    assert process.stderr is not None
    error_text = process.stderr.read().decode("utf-8", errors="replace").strip()
    process.stderr.close()
    return_code = process.wait()
    if return_code != 0:
        raise RuntimeError(error_text or f"FFmpeg exited with status {return_code}")
    return count


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="YubiBoardの手骨格JSONLを黒背景のMP4へ変換します。"
    )
    parser.add_argument("input", type=Path, help="hand-frames.jsonl")
    parser.add_argument("output", type=Path, nargs="?", help="出力MP4")
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--height", type=int, default=540)
    parser.add_argument("--fps", type=int, default=20)
    parser.add_argument(
        "--max-gap-ms",
        type=int,
        default=250,
        help="再接続や停止による空白時間の最大値（既定: 250ms）",
    )
    parser.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg実行ファイル")
    args = parser.parse_args(argv)
    if args.width < 2 or args.height < 2 or args.width % 2 or args.height % 2:
        parser.error("widthとheightは2以上の偶数にしてください")
    if not 1 <= args.fps <= 120:
        parser.error("fpsは1〜120にしてください")
    if args.max_gap_ms < 1:
        parser.error("max-gap-msは1以上にしてください")
    if args.output is None:
        args.output = args.input.with_name("hand-tracking.mp4")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if not args.input.is_file():
        print(f"入力ログが見つかりません: {args.input}", file=sys.stderr)
        return 2
    ffmpeg = shutil.which(args.ffmpeg)
    if ffmpeg is None:
        print(
            "FFmpegが見つかりません。PATHへ追加するか --ffmpeg で指定してください。",
            file=sys.stderr,
        )
        return 2
    frames, skipped = load_frames(args.input)
    if not frames:
        print("有効なhand_frameがログにありません。", file=sys.stderr)
        return 2
    timeline = build_timeline(frames, args.fps, args.max_gap_ms)
    try:
        output_count = render_video(
            timeline, args.output, args.width, args.height, args.fps, ffmpeg
        )
    except RuntimeError as error:
        print(f"動画生成に失敗しました: {error}", file=sys.stderr)
        return 1
    detected_count = sum(1 for frame in frames if frame.detected)
    two_hand_count = sum(1 for frame in frames if len(frame.hands) == 2)
    print(
        f"動画を生成しました: {args.output} "
        f"(受信{len(frames)}フレーム、手検出{detected_count}、2手{two_hand_count}、"
        f"出力{output_count}フレーム、スキップ{skipped})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

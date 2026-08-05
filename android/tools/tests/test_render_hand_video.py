import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "render_hand_video.py"
SPEC = importlib.util.spec_from_file_location("render_hand_video", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
render_hand_video = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = render_hand_video
SPEC.loader.exec_module(render_hand_video)


def make_message(frame_id: int, captured_at_ms: int, detected: bool = True) -> dict:
    hand = {"detected": detected}
    if detected:
        hand["landmarks"] = [
            [0.2 + (index % 5) * 0.12, 0.2 + (index // 5) * 0.12, -0.01 * index]
            for index in range(21)
        ]
    return {
        "receivedAtUtc": f"2026-08-05T08:00:00.{frame_id:03d}Z",
        "message": {
            "schemaVersion": 1,
            "messageType": "hand_frame",
            "sessionId": "session-test",
            "frameId": frame_id,
            "capturedAtMonotonicMs": captured_at_ms,
            "hand": hand,
        },
    }


class RenderHandVideoTest(unittest.TestCase):
    def test_parse_logged_frame_preserves_out_of_range_coordinates(self) -> None:
        message = make_message(1, 1000)
        message["message"]["hand"]["landmarks"][8][0] = 1.2

        frame = render_hand_video.parse_logged_frame(message)

        self.assertIsNotNone(frame)
        assert frame is not None
        self.assertEqual(21, len(frame.landmarks))
        self.assertEqual(1.2, frame.landmarks[8][0])

    def test_load_frames_skips_non_hand_and_invalid_lines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "hand-frames.jsonl"
            log.write_text(
                "\n".join(
                    (
                        json.dumps(make_message(1, 1000)),
                        '{"messageType":"heartbeat"}',
                        "not-json",
                        json.dumps(make_message(2, 1050, detected=False)),
                    )
                ),
                encoding="utf-8",
            )

            frames, skipped = render_hand_video.load_frames(log)

        self.assertEqual([1, 2], [frame.frame_id for frame in frames])
        self.assertEqual(2, skipped)
        self.assertFalse(frames[1].detected)

    def test_build_timeline_caps_long_gaps(self) -> None:
        frames = [
            render_hand_video.parse_logged_frame(make_message(1, 1000)),
            render_hand_video.parse_logged_frame(make_message(2, 1050)),
            render_hand_video.parse_logged_frame(make_message(3, 5050)),
        ]
        parsed = [frame for frame in frames if frame is not None]

        timeline = render_hand_video.build_timeline(parsed, fps=20, max_gap_ms=250)

        self.assertEqual(7, len(timeline))
        self.assertEqual(3, timeline[-1].frame_id)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is not installed")
    def test_render_video_writes_playable_mp4(self) -> None:
        frames = [
            render_hand_video.parse_logged_frame(make_message(1, 1000)),
            render_hand_video.parse_logged_frame(make_message(2, 1050)),
            render_hand_video.parse_logged_frame(make_message(3, 1100, detected=False)),
        ]
        parsed = [frame for frame in frames if frame is not None]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.mp4"

            count = render_hand_video.render_video(
                parsed,
                output,
                width=160,
                height=120,
                fps=10,
                ffmpeg=shutil.which("ffmpeg") or "ffmpeg",
            )

            self.assertEqual(3, count)
            self.assertTrue(output.is_file())
            self.assertGreater(output.stat().st_size, 500)


if __name__ == "__main__":
    unittest.main()

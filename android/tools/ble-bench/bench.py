"""BLE / WebSocket で手指フレームを送る経路の計測ツール（PC 側）。

Android 側は bench/TransportBenchActivity（network/ble/BenchProtocol.kt と対）。
時刻はすべて PC の単一の単調時計（time.perf_counter_ns）で測り、端末をまたいだ時計の引き算はしない。

使い方は README.md を参照。
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import math
import os
import statistics
import struct
import sys
import time
from dataclasses import dataclass, field

SERVICE_UUID = "6c8f0001-3c1e-4d7a-9b8e-5c2a7d1e0b17"
FRAME_UUID = "6c8f0002-3c1e-4d7a-9b8e-5c2a7d1e0b17"
CONTROL_UUID = "6c8f0003-3c1e-4d7a-9b8e-5c2a7d1e0b17"

CMD_PING, CMD_START, CMD_STOP = 0x01, 0x02, 0x03
RSP_PONG, RSP_ACK, RSP_STATS = 0x81, 0x82, 0x83
FRAME_MAGIC, FRAGMENT_MAGIC = 0x53, 0x46
PAYLOAD_KINDS = {"bin": 0, "json": 1}


def now_ns() -> int:
    return time.perf_counter_ns()


def nearest_rank(values: list[float], fraction: float) -> float | None:
    """Android 側 PerfWindow と同じ最近傍順位法の百分位数。"""
    if not values:
        return None
    ordered = sorted(values)
    # ceil(fraction * n)。丸めて浮動小数の誤差で 1 つずれないようにする。
    rank = max(1, min(len(ordered), math.ceil(round(fraction * len(ordered), 9))))
    return ordered[rank - 1]


@dataclass
class Condition:
    hands: int
    fps: int
    kind: str

    @property
    def name(self) -> str:
        return f"{self.hands}h-{self.fps}fps-{self.kind}"

    @staticmethod
    def parse(text: str) -> "Condition":
        hands, fps, kind = text.split(":")
        return Condition(int(hands), int(fps), kind)


@dataclass
class Run:
    condition: Condition
    started_ns: int = 0
    frames: dict[int, tuple[int, int, int]] = field(default_factory=dict)  # frameId -> (t_ns, bytes, units)
    fragments: dict[int, dict[int, bytes]] = field(default_factory=dict)
    units_received: int = 0
    unit_bytes_received: int = 0
    pings: dict[int, int] = field(default_factory=dict)
    rtts: list[tuple[int, float]] = field(default_factory=list)
    stats: dict | None = None

    def on_frame_unit(self, data: bytes, t_ns: int) -> None:
        self.units_received += 1
        self.unit_bytes_received += len(data)
        if not data:
            return
        head = data[0]
        if head == FRAME_MAGIC and len(data) >= 12:
            frame_id = struct.unpack_from("<I", data, 4)[0]
            self.frames.setdefault(frame_id, (t_ns, len(data), 1))
        elif head == FRAGMENT_MAGIC and len(data) >= 7:
            frame_id, index, count = struct.unpack_from("<IBB", data, 1)
            parts = self.fragments.setdefault(frame_id, {})
            parts[index] = data[7:]
            if len(parts) == count:
                payload = b"".join(parts[i] for i in range(count))
                del self.fragments[frame_id]
                self.frames.setdefault(frame_id, (t_ns, len(payload), count))
        elif head == ord("{"):
            frame_id = json.loads(data.decode("utf-8"))["frameId"]
            self.frames.setdefault(frame_id, (t_ns, len(data), 1))

    def on_control(self, data: bytes, t_ns: int) -> None:
        if not data:
            return
        if data[0] == RSP_PONG and len(data) == 5:
            seq = struct.unpack_from("<I", data, 1)[0]
            sent = self.pings.pop(seq, None)
            if sent is not None:
                self.rtts.append((seq, (t_ns - sent) / 1e6))
        elif data[0] == RSP_STATS and len(data) >= 27:
            values = struct.unpack_from("<IIIIIIH", data, 1)
            keys = ["generated", "framesSent", "replacedUnsent", "unitsSent", "unitFailures", "payloadBytesSent", "mtu"]
            self.stats = dict(zip(keys, values))

    def summary(self, transport: str, extra: dict) -> dict:
        arrivals = sorted(t for t, _, _ in self.frames.values())
        intervals = [(b - a) / 1e6 for a, b in zip(arrivals, arrivals[1:])]
        rtts = [r for _, r in self.rtts]
        span_s = (arrivals[-1] - arrivals[0]) / 1e9 if len(arrivals) > 1 else 0.0
        payload_bytes = sum(b for _, b, _ in self.frames.values())
        stats = self.stats or {}
        generated = stats.get("generated")
        sent = stats.get("framesSent")
        received = len(self.frames)
        units = [u for _, _, u in self.frames.values()]
        # frameId は START ごとに 1 から振り直す。1..最大受信 ID のうち届かなかった数。
        max_id = max(self.frames) if self.frames else 0
        missing_in_range = max_id - received

        def r(value, digits=2):
            return None if value is None else round(value, digits)

        return {
            "transport": transport,
            "condition": self.condition.name,
            "hands": self.condition.hands,
            "target_fps": self.condition.fps,
            "payload": self.condition.kind,
            "frame_bytes": r(payload_bytes / received, 0) if received else None,
            "units_per_frame": max(units) if units else None,
            "generated": generated,
            "sent_by_android": sent,
            "replaced_unsent": stats.get("replacedUnsent"),
            "unit_failures": stats.get("unitFailures"),
            "received": received,
            "loss_vs_generated_pct": r(100 * (1 - received / generated), 2) if generated else None,
            "missing_in_range": missing_in_range,
            "recv_fps": r((received - 1) / span_s, 1) if span_s else None,
            "interval_p50_ms": r(nearest_rank(intervals, 0.5)),
            "interval_p95_ms": r(nearest_rank(intervals, 0.95)),
            "interval_max_ms": r(max(intervals) if intervals else None),
            "throughput_kBps": r(payload_bytes / span_s / 1000, 2) if span_s else None,
            "link_kBps": r(self.unit_bytes_received / span_s / 1000, 2) if span_s else None,
            "rtt_n": len(rtts),
            "rtt_p50_ms": r(nearest_rank(rtts, 0.5)),
            "rtt_p95_ms": r(nearest_rank(rtts, 0.95)),
            "rtt_max_ms": r(max(rtts) if rtts else None),
            "rtt_mean_ms": r(statistics.fmean(rtts) if rtts else None),
            **extra,
        }


class Runner:
    """START → (ping を周期送信しながら) duration 秒受信 → STOP → STATS 受信、を条件ごとに行う。"""

    def __init__(self, send_control, duration: float, ping_interval: float):
        self.send_control = send_control
        self.duration = duration
        self.ping_interval = ping_interval
        self.run: Run | None = None
        self.ack = asyncio.Event()
        self.stats_event = asyncio.Event()
        self.seq = 0

    def on_frame_unit(self, data: bytes) -> None:
        t = now_ns()
        if self.run:
            self.run.on_frame_unit(bytes(data), t)

    def on_control(self, data: bytes) -> None:
        t = now_ns()
        data = bytes(data)
        if data[:1] == bytes([RSP_ACK]):
            self.ack.set()
        if self.run:
            self.run.on_control(data, t)
            if data[:1] == bytes([RSP_STATS]):
                self.stats_event.set()

    async def ping_loop(self, stop: asyncio.Event) -> None:
        while not stop.is_set():
            self.seq += 1
            self.run.pings[self.seq] = now_ns()
            await self.send_control(struct.pack("<BI", CMD_PING, self.seq))
            try:
                await asyncio.wait_for(stop.wait(), self.ping_interval)
            except asyncio.TimeoutError:
                pass

    async def measure(self, condition: Condition) -> Run:
        self.run = Run(condition)
        self.ack.clear()
        self.stats_event.clear()
        self.run.started_ns = now_ns()
        await self.send_control(struct.pack("<BBBB", CMD_START, condition.hands, condition.fps, PAYLOAD_KINDS[condition.kind]))
        await asyncio.wait_for(self.ack.wait(), 10)
        stop = asyncio.Event()
        pinger = asyncio.create_task(self.ping_loop(stop))
        await asyncio.sleep(self.duration)
        stop.set()
        await pinger
        await self.send_control(bytes([CMD_STOP]))
        try:
            await asyncio.wait_for(self.stats_event.wait(), 10)
        except asyncio.TimeoutError:
            print("  STATS を受け取れなかった", file=sys.stderr)
        await asyncio.sleep(0.5)  # 遅れて届く pong / フレームを拾う
        run, self.run = self.run, None
        return run


def write_outputs(out_dir: str, prefix: str, transport: str, runs: list[Run], summaries: list[dict]) -> None:
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, f"{prefix}-frames.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["transport", "condition", "frame_id", "t_ms", "bytes", "units"])
        for run in runs:
            for frame_id, (t, size, units) in sorted(run.frames.items(), key=lambda kv: kv[1][0]):
                w.writerow([transport, run.condition.name, frame_id, f"{(t - run.started_ns) / 1e6:.3f}", size, units])
    with open(os.path.join(out_dir, f"{prefix}-rtt.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["transport", "condition", "seq", "rtt_ms"])
        for run in runs:
            for seq, rtt in run.rtts:
                w.writerow([transport, run.condition.name, seq, f"{rtt:.3f}"])
    with open(os.path.join(out_dir, f"{prefix}-summary.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(summaries[0].keys()))
        w.writeheader()
        w.writerows(summaries)


def print_summary(summary: dict) -> None:
    keys = ["condition", "frame_bytes", "units_per_frame", "received", "loss_vs_generated_pct", "missing_in_range",
            "recv_fps", "interval_p50_ms", "interval_p95_ms", "throughput_kBps", "rtt_p50_ms", "rtt_p95_ms"]
    print("  " + ", ".join(f"{k}={summary.get(k)}" for k in keys), flush=True)


async def ble_connection_info(client) -> dict:
    """WinRT から MTU と接続間隔を読む（Windows 専用。取れなければ空）。"""
    info = {"mtu": getattr(client, "mtu_size", None)}
    try:
        device = client._backend._requester  # BluetoothLEDevice
        params = device.get_connection_parameters()
        info["conn_interval_ms"] = round(params.connection_interval * 1.25, 2)
        info["peripheral_latency"] = params.connection_latency
        info["supervision_timeout_ms"] = params.link_timeout * 10
        phy = device.get_connection_phy()
        info["phy_tx_2m"] = bool(phy.transmit_info.is_uncoded_2m_phy)
        info["phy_rx_2m"] = bool(phy.receive_info.is_uncoded_2m_phy)
    except Exception as error:  # noqa: BLE001
        info["conn_info_error"] = repr(error)
    return info


async def ble_request_params(client, mode: str) -> str:
    if mode == "none":
        return "not requested"
    try:
        from winrt.windows.devices.bluetooth import BluetoothLEPreferredConnectionParameters as P

        params = {"throughput": P.throughput_optimized, "balanced": P.balanced, "power": P.power_optimized}[mode]
        request = client._backend._requester.request_preferred_connection_parameters(params)
        return f"{mode}: status={request.status}"
    except Exception as error:  # noqa: BLE001
        return f"{mode}: failed {error!r}"


async def run_ble(args, conditions: list[Condition]) -> None:
    from bleak import BleakClient, BleakScanner

    print("scan ...", flush=True)
    device = await BleakScanner.find_device_by_filter(
        lambda d, ad: SERVICE_UUID in [u.lower() for u in ad.service_uuids], timeout=args.scan_timeout
    )
    if device is None:
        raise SystemExit("advertising が見つからない")
    t0 = now_ns()
    async with BleakClient(device, timeout=30) as client:
        print(f"connected in {(now_ns() - t0) / 1e6:.0f} ms", flush=True)
        runner = Runner(lambda data: client.write_gatt_char(CONTROL_UUID, data, response=True), args.duration, args.ping_interval)
        await client.start_notify(FRAME_UUID, lambda _, data: runner.on_frame_unit(data))
        await client.start_notify(CONTROL_UUID, lambda _, data: runner.on_control(data))
        request_status = await ble_request_params(client, args.conn_params)
        await asyncio.sleep(2)
        print(f"conn params request: {request_status}; {await ble_connection_info(client)}", flush=True)
        runs, summaries = [], []
        for condition in conditions:
            print(f"[ble] {condition.name} {args.duration}s", flush=True)
            run = await runner.measure(condition)
            info = await ble_connection_info(client)
            summary = run.summary("ble", {**info, "conn_params_request": args.conn_params})
            print_summary(summary)
            runs.append(run)
            summaries.append(summary)
            write_outputs(args.out, args.prefix, "ble", runs, summaries)
        await client.stop_notify(FRAME_UUID)
        await client.stop_notify(CONTROL_UUID)


async def run_ws(args, conditions: list[Condition]) -> None:
    import websockets

    connected: asyncio.Future = asyncio.get_running_loop().create_future()

    async def handler(ws):
        if connected.done():
            await ws.close()
            return
        print(f"android connected from {ws.remote_address[0]}", flush=True)
        connected.set_result(ws)
        await ws.wait_closed()

    async with websockets.serve(handler, args.bind, args.port, max_size=None, compression=None):
        print(f"ws listening on {args.bind}:{args.port}", flush=True)
        ws = await asyncio.wait_for(connected, args.scan_timeout)
        runner = Runner(lambda data: ws.send(data), args.duration, args.ping_interval)

        async def reader():
            async for message in ws:
                data = message.encode("utf-8") if isinstance(message, str) else message
                if data[:1] in (bytes([RSP_PONG]), bytes([RSP_ACK]), bytes([RSP_STATS])):
                    runner.on_control(data)
                else:
                    runner.on_frame_unit(data)

        reader_task = asyncio.create_task(reader())
        runs, summaries = [], []
        for condition in conditions:
            print(f"[{args.label}] {condition.name} {args.duration}s", flush=True)
            run = await runner.measure(condition)
            summary = run.summary(args.label, {})
            print_summary(summary)
            runs.append(run)
            summaries.append(summary)
            write_outputs(args.out, args.prefix, args.label, runs, summaries)
        await ws.close()
        reader_task.cancel()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("transport", choices=["ble", "ws"])
    parser.add_argument("--conditions", default="1:20:bin,1:30:bin,1:60:bin,2:20:bin,2:30:bin,2:60:bin,1:20:json",
                        help="hands:fps:bin|json をカンマ区切り")
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--ping-interval", type=float, default=0.2)
    parser.add_argument("--out", default=".")
    parser.add_argument("--prefix", default=None)
    parser.add_argument("--scan-timeout", type=float, default=60.0)
    parser.add_argument("--conn-params", choices=["throughput", "balanced", "power", "none"], default="throughput")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--label", default="ws", help="ws の結果の transport 列の値（例 ws-lan / ws-usb）")
    args = parser.parse_args()
    args.prefix = args.prefix or (args.transport if args.transport == "ble" else args.label)
    conditions = [Condition.parse(c) for c in args.conditions.split(",")]
    asyncio.run(run_ble(args, conditions) if args.transport == "ble" else run_ws(args, conditions))


if __name__ == "__main__":
    main()

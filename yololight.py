#!/usr/bin/env python3
"""Direct BLE control for YoloLight Air. No camera, firmware update, or pairing required.

Run with this project's virtualenv: .venv/bin/python yololight.py --help
Protocol recovered from official camera firmware and validated on the light.
"""
from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass
import json
import sys

from bleak import BleakClient
from connection import find_light, scan_lights

CONTROL = "0000fff1-0000-1000-8000-00805f9b34fb"


def build_frame(mac: bytes, command: int, kind: int, sequence: int, data: bytes = b"") -> bytes:
    if len(mac) != 6:
        raise ValueError("Packet identity must contain exactly six bytes")
    if not 0 <= sequence <= 0xffff:
        raise ValueError("Sequence must fit in 16 bits")
    payload = bytes([command, kind]) + sequence.to_bytes(2, "big") + data
    if len(payload) > 8:
        raise ValueError("Controller only supports small, single-write control packets")
    packet = b"\xff\xcc" + bytes([len(payload) + 9, 0xe4]) + mac + bytes([len(payload) + 1]) + payload
    return packet + bytes([sum(packet) & 0xff])


@dataclass(frozen=True)
class Frame:
    mac: bytes
    command: int
    kind: int
    sequence: int
    data: bytes


def parse_frame(packet: bytes) -> Frame:
    if len(packet) < 16 or packet[:2] != b"\xff\xcc" or packet[3] != 0xe4:
        raise ValueError("Not a control frame")
    if packet[2] + 3 != len(packet) or packet[10] + 11 != len(packet):
        raise ValueError("Invalid frame length")
    if sum(packet[:-1]) & 0xff != packet[-1]:
        raise ValueError("Invalid checksum")
    return Frame(packet[4:10], packet[11], packet[12], int.from_bytes(packet[13:15], "big"), packet[15:-1])


class YoloLight:
    def __init__(self, address: str, mac: bytes):
        if not address.strip():
            raise ValueError("A BLE peripheral address is required")
        if len(mac) != 6:
            raise ValueError("Packet identity must contain exactly six bytes")
        self.address = address
        self.mac = mac
        self.client: BleakClient | None = None
        self.sequence = 0
        self.replies: asyncio.Queue[Frame] = asyncio.Queue()
        self.lock = asyncio.Lock()

    def _notify(self, characteristic, value: bytearray) -> None:
        packet = bytes(value)
        try:
            reply = parse_frame(packet)
        except ValueError:
            # The unsolicited A4 device-type announcement has a nonstandard
            # checksum/layout. Firmware explicitly special-cases it; we ignore it.
            return
        if reply.mac == self.mac:
            self.replies.put_nowait(reply)

    async def __aenter__(self) -> YoloLight:
        device = await find_light(self.address)
        if device.name != "YLight":
            raise RuntimeError(f"Refusing control of unexpected device: {device.name!r}")
        self.client = BleakClient(device, timeout=15)
        try:
            await self.client.connect()
            characteristic = self.client.services.get_characteristic(CONTROL)
            if characteristic is None or not {"write", "notify"}.issubset(characteristic.properties):
                raise RuntimeError("Expected YLight control characteristic not found")
            await self.client.start_notify(CONTROL, self._notify)
            return self
        except BaseException:
            await self.client.disconnect()
            raise

    async def __aexit__(self, *exc) -> None:
        if self.client is not None:
            await self.client.disconnect()

    async def _send(self, command: int, kind: int, data: bytes = b"") -> None:
        if self.client is None or not self.client.is_connected:
            raise RuntimeError("Light is not connected")
        self.sequence = (self.sequence + 1) & 0xffff
        packet = build_frame(self.mac, command, kind, self.sequence, data)
        await self.client.write_gatt_char(CONTROL, packet, response=True)

    async def _query(self, command: int, size: int) -> bytes:
        # Callers hold self.lock. Device replies use sequence FFFF rather than
        # echoing the request, so match by command/type and never overlap queries.
        while not self.replies.empty():
            self.replies.get_nowait()
        await self._send(command, 2)
        try:
            async with asyncio.timeout(4):
                while True:
                    reply = await self.replies.get()
                    if reply.command == command and reply.kind == 2:
                        if len(reply.data) != size:
                            raise RuntimeError(f"Unexpected payload length for command {command:02x}")
                        return reply.data
        except TimeoutError as exc:
            raise RuntimeError(f"No valid response to status command {command:02x}; no result assumed") from exc

    async def status(self) -> dict:
        async with self.lock:
            power = int.from_bytes(await self._query(0xa1, 1), "big")
            brightness = int.from_bytes(await self._query(0xa2, 1), "big")
            temperature = int.from_bytes(await self._query(0xa3, 2), "big")
            limits = await self._query(0xa5, 4)
            return {
                "power": "on" if power else "off",
                "brightness_percent": brightness,
                "temperature_kelvin": temperature,
                "temperature_range_kelvin": [int.from_bytes(limits[:2], "big"), int.from_bytes(limits[2:], "big")],
            }

    async def _set_verified(self, command: int, value: int, size: int) -> int:
        # Called with the lock held. GATT success alone does not prove the light
        # acted; always query the value after setting it.
        await self._send(command, 1, value.to_bytes(size, "big"))
        await asyncio.sleep(0.25)
        actual = int.from_bytes(await self._query(command + 0xa0, size), "big")
        if actual != value:
            raise RuntimeError(f"Requested {value}, but device reports {actual}")
        return actual

    async def brightness(self, percent: int) -> int:
        if not 0 <= percent <= 100:
            raise ValueError("Brightness must be 0–100 percent")
        async with self.lock:
            return await self._set_verified(2, percent, 1)

    async def temperature(self, kelvin: int) -> int:
        async with self.lock:
            limits = await self._query(0xa5, 4)
            low, high = int.from_bytes(limits[:2], "big"), int.from_bytes(limits[2:], "big")
            if not low <= kelvin <= high or kelvin % 100:
                raise ValueError(f"Temperature must be {low}–{high} K, in 100 K steps")
            return await self._set_verified(3, kelvin, 2)

    async def power(self, on: bool) -> int:
        async with self.lock:
            return await self._set_verified(1, int(on), 1)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--address", help="BLE peripheral identifier; required except for scan")
    p.add_argument("--mac", help="Six-byte packet identity in advertisement order; required except for scan")
    commands = p.add_subparsers(dest="command", required=True)
    scan = commands.add_parser("scan", help="Discover advertising lights without connecting or changing settings")
    scan.add_argument("--timeout", type=float, default=15,
                      help="Scan duration in seconds (default: 15; must be finite and positive)")
    commands.add_parser("status", help="Read power, brightness, temperature and temperature limits")
    commands.add_parser("on", help="Turn light output on (hardware power switch must remain on)")
    commands.add_parser("off", help="Turn light output off, retaining BLE connectivity")
    commands.add_parser("brightness", help="Set brightness and verify readback").add_argument("percent", type=int)
    commands.add_parser("temperature", help="Set color temperature and verify readback").add_argument("kelvin", type=int)
    return p


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = parser()
    args = p.parse_args(argv)
    if args.command == "scan":
        if not 0 < args.timeout < float("inf"):
            p.error("--timeout must be finite and greater than zero")
    else:
        missing = [f"--{name}" for name in ("address", "mac") if not getattr(args, name)]
        if missing:
            p.error(f"the following arguments are required for {args.command}: {', '.join(missing)}")
    return args


async def run(args: argparse.Namespace) -> None:
    if args.command == "scan":
        print(json.dumps(await scan_lights(args.timeout), indent=2))
        return
    mac = bytes.fromhex(args.mac.replace(":", ""))
    if len(mac) != 6:
        raise ValueError("--mac must contain six bytes")
    if args.command == "brightness" and not 0 <= args.percent <= 100:
        raise ValueError("Brightness must be 0–100 percent")
    async with YoloLight(args.address, mac) as light:
        if args.command == "brightness":
            await light.brightness(args.percent)
        elif args.command == "temperature":
            await light.temperature(args.kelvin)
        elif args.command in ("on", "off"):
            await light.power(args.command == "on")
        print(json.dumps(await light.status(), indent=2))


if __name__ == "__main__":
    try:
        asyncio.run(run(parse_args()))
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

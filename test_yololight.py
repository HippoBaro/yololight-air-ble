"""Offline tests using synthetic device identities; no hardware access."""
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from connection import IDENTITY_SERVICE, scan_lights
from yololight import CONTROL, Frame, YoloLight, build_frame, parse_frame, parse_args, run

# Preserve validated wire layouts without publishing real device identifiers.
DEVICE_MAC = bytes.fromhex("020000000001")
ADDRESS = "00000000-0000-0000-0000-000000000001"


class ProtocolTests(unittest.TestCase):
    def test_query_packet(self):
        self.assertEqual(build_frame(DEVICE_MAC, 0xa2, 2, 1).hex(),
                         "ffcc0de402000000000105a202000169")

    def test_brightness_set(self):
        self.assertEqual(build_frame(DEVICE_MAC, 2, 1, 12, b"\x14").hex(),
                         "ffcc0ee4020000000001060201000c14e9")

    def test_temperature_set(self):
        self.assertEqual(build_frame(DEVICE_MAC, 3, 1, 23, (3900).to_bytes(2, "big")).hex(),
                         "ffcc0fe402000000000107030100170f3c2e")

    def test_reply_layouts(self):
        samples = [
            ("ffcc0ee402000000000106a202ffff1981", 0xa2, b"\x19"),
            ("ffcc0fe402000000000107a302ffff0fa01a", 0xa3, b"\x0f\xa0"),
            ("ffcc0ee402000000000106a102ffff0168", 0xa1, b"\x01"),
            ("ffcc11e402000000000109a502ffff0a8c196484", 0xa5, b"\x0a\x8c\x19\x64"),
        ]
        for hex_string, command, data in samples:
            with self.subTest(command=command):
                self.assertEqual(parse_frame(bytes.fromhex(hex_string)),
                                 Frame(DEVICE_MAC, command, 2, 0xffff, data))

    def test_invalid_packets(self):
        valid = build_frame(DEVICE_MAC, 0xa2, 2, 1)
        for packet in [b"", valid[:-1], valid + b"\x00", b"\x00" + valid[1:],
                       valid[:-1] + bytes([valid[-1] ^ 1]),
                       bytes.fromhex("ffcc0de402000000000105a4f1ff05ff")]:
            with self.subTest(packet=packet.hex()):
                with self.assertRaises(ValueError):
                    parse_frame(packet)

    def test_invalid_build(self):
        for mac, seq, data in [(b"abc", 1, b""), (DEVICE_MAC, -1, b""),
                               (DEVICE_MAC, 65536, b""), (DEVICE_MAC, 1, b"12345")]:
            with self.assertRaises(ValueError):
                build_frame(mac, 2, 1, seq, data)


class FakeClient:
    is_connected = True

    def __init__(self, light):
        self.light = light
        self.values = {0xa1: b"\x01", 0xa2: b"\x19", 0xa3: b"\x0f\xa0", 0xa5: b"\x0a\x8c\x19\x64"}
        self.writes = []
        self.ignore_sets = False

    async def write_gatt_char(self, characteristic, packet, response):
        assert characteristic == CONTROL and response is True
        frame = parse_frame(packet)
        self.writes.append(frame)
        if frame.kind == 1 and not self.ignore_sets:
            self.values[frame.command + 0xa0] = frame.data
        if frame.kind == 2:
            reply = build_frame(DEVICE_MAC, frame.command, 2, 0xffff, self.values[frame.command])
            self.light._notify(None, bytearray(reply))


class ControllerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.light = YoloLight(ADDRESS, DEVICE_MAC)
        self.fake = FakeClient(self.light)
        self.light.client = self.fake

    async def test_status(self):
        self.assertEqual(await self.light.status(), {
            "power": "on", "brightness_percent": 25, "temperature_kelvin": 4000,
            "temperature_range_kelvin": [2700, 6500],
        })
        self.assertTrue(all(f.kind == 2 for f in self.fake.writes))

    async def test_setters_verify_readback(self):
        self.assertEqual(await self.light.brightness(20), 20)
        self.assertEqual(await self.light.temperature(3900), 3900)
        self.assertEqual(await self.light.power(False), 0)
        self.assertEqual(await self.light.power(True), 1)
        state = await self.light.status()
        self.assertEqual(state["brightness_percent"], 20)
        self.assertEqual(state["temperature_kelvin"], 3900)

    async def test_invalid_brightness_does_not_write(self):
        for value in [-1, 101]:
            with self.assertRaises(ValueError):
                await self.light.brightness(value)
        self.assertEqual(self.fake.writes, [])

    async def test_invalid_temperature_only_queries_limits(self):
        for value in [2600, 6600, 4001]:
            with self.assertRaises(ValueError):
                await self.light.temperature(value)
        self.assertTrue(all(f.command == 0xa5 and f.kind == 2 for f in self.fake.writes))

    async def test_mismatching_readback_fails(self):
        self.fake.ignore_sets = True
        with self.assertRaisesRegex(RuntimeError, "Requested 20, but device reports 25"):
            await self.light.brightness(20)

    async def test_ignores_foreign_or_invalid_notifications(self):
        self.light._notify(None, bytearray(b"junk"))
        self.light._notify(None, bytearray(build_frame(b"abcdef", 0xa2, 2, 1, b"\x19")))
        self.assertTrue(self.light.replies.empty())

    async def test_wrong_size_reply_fails(self):
        self.fake.values[0xa2] = b"\x00\x19"
        with self.assertRaisesRegex(RuntimeError, "payload length"):
            async with self.light.lock:
                await self.light._query(0xa2, 1)

    async def test_stale_reply_is_discarded(self):
        self.light.replies.put_nowait(Frame(DEVICE_MAC, 0xa2, 2, 0xffff, b"\x64"))
        async with self.light.lock:
            self.assertEqual(await self.light._query(0xa2, 1), b"\x19")

    async def test_timeout_does_not_assume_success(self):
        self.fake.write_gatt_char = AsyncMock()
        self.light.replies.get = AsyncMock(side_effect=TimeoutError)
        async with self.light.lock:
            with self.assertRaisesRegex(RuntimeError, "No valid response"):
                await self.light._query(0xa2, 1)


class ScanTests(unittest.IsolatedAsyncioTestCase):
    @staticmethod
    def advertisement(address=ADDRESS, name="YLight", local_name="YLight",
                      identity=b"\xff" + DEVICE_MAC, rssi=-50):
        device = SimpleNamespace(address=address, name=name)
        adv = SimpleNamespace(local_name=local_name, rssi=rssi,
                              service_data={} if identity is None else {IDENTITY_SERVICE: identity})
        return device, adv

    async def test_extracts_identity_in_wire_order(self):
        with patch("connection.BleakScanner.discover", new_callable=AsyncMock,
                   return_value={ADDRESS: self.advertisement()}) as discover:
            self.assertEqual(await scan_lights(2.5), [{
                "name": "YLight", "address": ADDRESS, "mac": DEVICE_MAC.hex(), "rssi": -50,
            }])
            discover.assert_awaited_once_with(timeout=2.5, return_adv=True)

    async def test_multiple_lights_strongest_first(self):
        second_mac = bytes.fromhex("020000000002")
        devices = {
            "weak": self.advertisement(address="weak", rssi=-80),
            "strong": self.advertisement(address="strong", rssi=-40, identity=b"\xff" + second_mac),
        }
        with patch("connection.BleakScanner.discover", new_callable=AsyncMock, return_value=devices):
            lights = await scan_lights()
            self.assertEqual([light["address"] for light in lights], ["strong", "weak"])
            self.assertEqual(lights[0]["mac"], second_mac.hex())

    async def test_name_fallback_and_filtering(self):
        devices = {
            "cached-name": self.advertisement(address="cached-name", local_name=None),
            "local-name": self.advertisement(address="local-name", name=None),
            "unrelated": self.advertisement(name="Other device", local_name="Other device"),
            "unnamed": self.advertisement(name=None, local_name=None),
            "conflicting-name": self.advertisement(name="YLight", local_name="Other device"),
        }
        with patch("connection.BleakScanner.discover", new_callable=AsyncMock, return_value=devices):
            lights = await scan_lights()
            self.assertEqual([light["address"] for light in lights], ["cached-name", "local-name"])

    async def test_skips_missing_or_malformed_identity(self):
        malformed = [None, b"", b"\xff", DEVICE_MAC, b"\x00" + DEVICE_MAC,
                     b"\xff" + DEVICE_MAC + b"\x00"]
        devices = {str(i): self.advertisement(identity=value) for i, value in enumerate(malformed)}
        with patch("connection.BleakScanner.discover", new_callable=AsyncMock, return_value=devices):
            self.assertEqual(await scan_lights(), [])

    async def test_empty_scan(self):
        with patch("connection.BleakScanner.discover", new_callable=AsyncMock, return_value={}):
            self.assertEqual(await scan_lights(), [])

    async def test_invalid_timeout_does_not_scan(self):
        with patch("connection.BleakScanner.discover", new_callable=AsyncMock) as discover:
            for timeout in [0, -1, float("nan"), float("inf"), float("-inf")]:
                with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                    await scan_lights(timeout)
            discover.assert_not_awaited()

    async def test_scan_error_is_not_hidden(self):
        with patch("connection.BleakScanner.discover", new_callable=AsyncMock,
                   side_effect=RuntimeError("Bluetooth unavailable")):
            with self.assertRaisesRegex(RuntimeError, "Bluetooth unavailable"):
                await scan_lights()

    async def test_scan_command_prints_json_without_connecting(self):
        devices = {ADDRESS: self.advertisement()}
        output = io.StringIO()
        with patch("connection.BleakScanner.discover", new_callable=AsyncMock, return_value=devices), \
                patch("yololight.YoloLight") as controller, patch("yololight.BleakClient") as client, \
                redirect_stdout(output):
            await run(parse_args(["scan", "--timeout", "0.5"]))
        self.assertEqual(json.loads(output.getvalue()), [{
            "name": "YLight", "address": ADDRESS, "mac": DEVICE_MAC.hex(), "rssi": -50,
        }])
        controller.assert_not_called()
        client.assert_not_called()

    async def test_empty_scan_command_prints_empty_array(self):
        output = io.StringIO()
        with patch("connection.BleakScanner.discover", new_callable=AsyncMock, return_value={}), \
                redirect_stdout(output):
            await run(parse_args(["scan"]))
        self.assertEqual(json.loads(output.getvalue()), [])


class ConfigurationTests(unittest.TestCase):
    def test_device_identifiers_are_required_for_control_commands(self):
        for command in [["status"], ["on"], ["off"], ["brightness", "30"], ["temperature", "4500"]]:
            for prefix in [[], ["--address", ADDRESS], ["--mac", DEVICE_MAC.hex()]]:
                arguments = prefix + command
                with self.subTest(arguments=arguments), redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        parse_args(arguments)
                    self.assertEqual(error.exception.code, 2)

    def test_explicit_identifiers(self):
        args = parse_args(["--address", ADDRESS, "--mac", DEVICE_MAC.hex(), "status"])
        self.assertEqual((args.address, args.mac, args.command), (ADDRESS, DEVICE_MAC.hex(), "status"))

    def test_scan_requires_no_identifiers(self):
        args = parse_args(["scan"])
        self.assertEqual((args.address, args.mac, args.command, args.timeout), (None, None, "scan", 15))

    def test_scan_custom_timeout(self):
        self.assertEqual(parse_args(["scan", "--timeout", "2.5"]).timeout, 2.5)

    def test_scan_invalid_timeout(self):
        for value in ["0", "-1", "nan", "inf", "-inf", "invalid"]:
            with self.subTest(value=value), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    parse_args(["scan", f"--timeout={value}"])
                self.assertEqual(error.exception.code, 2)

    def test_invalid_identifiers(self):
        for address, mac in [(" ", DEVICE_MAC), (ADDRESS, b"abc")]:
            with self.subTest(address=address, mac=mac), self.assertRaises(ValueError):
                YoloLight(address, mac)


if __name__ == "__main__":
    unittest.main()

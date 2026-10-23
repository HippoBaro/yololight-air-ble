# YoloLight Air BLE controller

Control a YoloLight Air directly over Bluetooth Low Energy, without a YoloCam S3.
The controller supports light discovery, status queries, brightness, color
temperature, and power, and verifies every setting change by querying the light
afterward.

## Requirements and installation

- Python 3.11 or newer.
- A Bluetooth adapter and a powered-on YoloLight Air within range.
- Bluetooth access for the terminal or application running Python, where required.

From the project directory:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

The Bleak dependency version is pinned to keep Bluetooth backend integration
reproducible. The commands below use the environment's interpreter explicitly.
After activating it with `source .venv/bin/activate`, you can also invoke the
executable directly, for example `./yololight.py scan`.

## Identify your light

Scan for nearby advertising lights without connecting or sending control commands:

```sh
.venv/bin/python yololight.py scan
.venv/bin/python yololight.py scan --timeout 30
```

`scan` requires no device identifiers. It listens for advertisements for 15 seconds
by default; `--timeout` accepts a positive, finite duration in seconds. It prints
a JSON array, sorted by strongest signal first. For example (synthetic identifiers):

```json
[
  {
    "name": "YLight",
    "address": "00000000-0000-0000-0000-000000000001",
    "mac": "020000000001",
    "rssi": -50
  }
]
```

`rssi` is the received signal strength in dBm; values closer to zero indicate a
stronger signal. Only `YLight` advertisements containing valid packet-identity
data are included. If none are found, the output is `[]`. Bluetooth access errors
are reported as errors, not empty results. No scan results are saved to disk.

Use the discovered `address` and `mac` for control commands. Both are required
for those commands, and neither is hard-coded in the controller:

- **`--address`**: the peripheral identifier returned by Bleak. Use the exact
  value from discovery; depending on the backend, it may be a UUID or a Bluetooth
  address. This is distinct from the packet identity supplied with `--mac`.
- **`--mac`**: the six-byte identity embedded in control packets, in advertisement
  order. The scanner extracts it from the light's service data for UUID `AAAB`,
  following a leading `FF` byte. Do not reverse its bytes. Hex with or without
  colons is accepted.

**Scanning limitation:** `scan` can only pick up lights that are advertising and
not already connected to another Bluetooth device. A light already connected to
this host can also be absent from scan results, even though it remains
controllable using its known `address` and `mac`.

If there are multiple lights, identify the intended one before using the printed
values. If a light is absent from scans, disconnect it from its current Bluetooth
host and power-cycle it if necessary. Where supported by the active Bluetooth
backend, `connection.py` can also retrieve known peripherals that no longer
appear in scans.

## Usage

Replace the placeholders with your own identifiers:

```sh
export YOLOLIGHT_ADDRESS='<peripheral identifier>'
export YOLOLIGHT_MAC='<six-byte packet identity>'

yololight() {
    .venv/bin/python yololight.py \
        --address "$YOLOLIGHT_ADDRESS" --mac "$YOLOLIGHT_MAC" "$@"
}

yololight status
yololight brightness 30
yololight temperature 4500
yololight on
yololight off
```

The shell function forwards the identifiers explicitly; the Python program does
not read environment variables itself.

**Automatic connection:** When you interact with a selected light through a CLI
status or control command, the CLI automatically attempts to establish a Bluetooth
connection between the host and the light if they are not already connected. No
separate connection command is needed. Once connected, the light may stop
advertising and disappear from subsequent scans, so retain its `address` and
`mac` for future commands. The `scan` command itself does not connect to lights.

- **Brightness:** 0–100%.
- **Temperature:** the tested light reports 2700–6500 K. The controller queries
  its limits before setting a temperature and accepts 100 K steps.
- **Power:** controls light output, not the electrical supply. Keep the hardware
  power switch on for remote access.
- **Verification:** a successful GATT write alone is not considered success.
  Set operations query the value and fail on a mismatch or timeout.
- **Concurrency:** use only one controller process at a time. Replies use sequence
  `FFFF` rather than echoing requests, so concurrent clients cannot reliably
  correlate replies.

Successful commands print JSON, for example:

```json
{
  "power": "on",
  "brightness_percent": 25,
  "temperature_kelvin": 4000,
  "temperature_range_kelvin": [2700, 6500]
}
```

For Python integrations:

```python
from yololight import YoloLight

async def configure(address: str, packet_identity: bytes):
    async with YoloLight(address, packet_identity) as light:
        await light.brightness(30)
        await light.temperature(4500)
        return await light.status()
```

## Tests and verification scope

```sh
.venv/bin/python -m unittest -v test_yololight.py
```

Tests are entirely offline and use synthetic device identities. They cover known
wire layouts, checksums, malformed responses, input validation, foreign and stale
notifications, timeouts, CLI configuration, and readback failures. Discovery tests
cover multiple lights, name and identity filtering, signal-strength ordering,
empty results, scanner errors, timeout validation, and connection-free execution.

Hardware validation covered power/brightness/temperature/range queries, brightness
changes from 25% to 20% and back, and temperature changes from 4000 K to 3900 K and
back. Each change was verified by device readback. The `on` command was tested
while already on. **`off` is implemented from the recovered switch-control
function but has not been exercised on hardware.** No flashing or firmware-update
commands are implemented.

## BLE interface

| Item | Value |
|---|---|
| Advertised name | `YLight` |
| Advertised service | `1812` (HID; not the control service) |
| Manufacturer data observed | Company `FFF1`, payload `05 FF` |
| Advertisement service data | UUID `AAAB`, payload `FF` followed by six identity bytes |
| Control service | `0000fff0-0000-1000-8000-00805f9b34fb` |
| **Write and notify characteristic** | **`0000fff1-0000-1000-8000-00805f9b34fb`** |

Subscribe to FFF1 notifications before sending commands. Writes **with response**
were validated. Ordinary FFF1 reads return the static text `CHAR1_VALUE`; real
status arrives through notifications in response to queries.

FFF2 is also writable but did not respond to the tested queries. FFF3 is a
version-like read-only characteristic. Neither is used by this controller.

The separate service `02f00000-0000-0000-0000-00000000fe00` exposes update-related
characteristics. The controller does not access it; do not send control packets
there.

## Wire protocol

A complete control frame is written to FFF1:

```text
FF CC L E4 MAC[6] N CMD TYPE SEQ_HI SEQ_LO DATA[...] CHECKSUM
```

- `payload = CMD TYPE SEQ_HI SEQ_LO DATA...`
- `L = len(payload) + 9`, or the complete frame length minus 3.
- `N = len(payload) + 1`.
- `MAC[6]` is the packet identity in advertisement order.
- Sequence numbers are unsigned 16-bit, big-endian; increment per request.
- `CHECKSUM = sum(all preceding frame bytes) & 0xFF`.
- Observed query replies use sequence `FFFF`, not the request's sequence.

| Operation | CMD | TYPE | Request data / reply data |
|---|---:|---:|---|
| Query power | `A1` | `02` | Empty request; one-byte reply (`00`/`01`) |
| Query brightness | `A2` | `02` | Empty request; one-byte percentage reply |
| Query temperature | `A3` | `02` | Empty request; two-byte big-endian kelvin reply |
| Query temperature limits | `A5` | `02` | Empty request; min/max kelvin, two bytes each |
| Set power | `01` | `01` | `00` = off, `01` = on |
| Set brightness | `02` | `01` | Percentage byte |
| Set temperature | `03` | `01` | Two-byte big-endian kelvin |

### Example frames

These preserve validated packet layouts but use the **synthetic** identity
`02 00 00 00 00 01`. They are not packets for a particular user's light.

Query brightness, sequence 1:

```text
FF CC 0D E4 02 00 00 00 00 01 05 A2 02 00 01 69
```

Reply for 25%:

```text
FF CC 0E E4 02 00 00 00 00 01 06 A2 02 FF FF 19 81
```

Set brightness to 20%, sequence 12:

```text
FF CC 0E E4 02 00 00 00 00 01 06 02 01 00 0C 14 E9
```

Set temperature to 3900 K, sequence 23:

```text
FF CC 0F E4 02 00 00 00 00 01 07 03 01 00 17 0F 3C 2E
```

Temperature-range reply (`0A8C` = 2700, `1964` = 6500):

```text
FF CC 11 E4 02 00 00 00 00 01 09 A5 02 FF FF 0A 8C 19 64 84
```

An unsolicited A4 device-type announcement can arrive when notifications are
enabled. Its checksum/payload layout is nonstandard; the vendor parser
special-cases it. The controller ignores it rather than weakening response
validation. No response or handshake to this announcement was needed.

## Protocol provenance

The protocol was independently implemented after offline inspection of
**YoloLiv Compose 1.1.3** and the official S3 firmware
**`YunxiCamera-ch131b-20260831-1.0.4`**, subversion **1349**, then validated on a
light. No vendor executables or update scripts were run.

The firmware's `/lib64/libcomm_svc.so` retains symbols for
`BleProtocolHelper::buildProtocolData`, `buildUnicastDataCmd`, and
`parseDataTransmissionResponse`, plus `BleUartService` functions for querying and
setting power, brightness, and color temperature. These identify the framing,
checksum, command IDs, and byte order documented above.

Compose's camera protobuf command IDs (83/85/86/87) are **not** the direct BLE
command bytes in this document.

Source: [official firmware archive](https://yunxi-material-library-prod.oss-accelerate.aliyuncs.com/vendor/assistant/YunxiCamera-ch131b-20260831-1.0.4.tar.gz).
The download was returned by `POST https://b-api.yunxi.tv/api/box/version-query`
with JSON `{"productType":51,"installPackageType":2}`. No vendor binaries, copied
application source, packet logs, or third-party repositories are distributed here.

## Project files

- `yololight.py`: protocol implementation, controller, and CLI.
- `connection.py`: BLE peripheral discovery and cached-peripheral retrieval.
- `requirements.txt`: pinned runtime dependency.
- `test_yololight.py`: offline tests.
- `README.md`: setup, usage, validation scope, and protocol documentation.
- `.gitignore`: excludes local environments and generated files.

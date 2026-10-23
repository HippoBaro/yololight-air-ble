# YoloLight Air menu-bar app

A native macOS menu-bar app with standard SwiftUI controls and CoreBluetooth.
AppKit hosts the menu-bar item and fixed popover; the panel uses SwiftUI throughout,
including a system switch (`Toggle` with `.switch` style) and `Slider` controls.
There are no custom control subclasses or `NSViewRepresentable` control wrappers.
It lists nearby advertising YoloLights alongside lights already connected to
macOS, with independent controls for each. No Python runtime, camera, saved-device
selection, scan button, settings gear, or settings window is needed.

## Installation

For a published release, use the [same-repository Homebrew tap](../Casks/README.md).
The cask initially supports Apple Silicon on macOS 14 or newer. Releases use
free ad-hoc signing by default and are not notarized; macOS may require per-app
approval on first launch. Before the first release and generated cask are
published, use the [source build](#build).

## Use

1. Turn on your light and keep it within Bluetooth range.
2. Launch the app and click the menu-bar lightbulb. Allow Bluetooth access if
   macOS requests it. Nearby lights appear automatically; discovery does not
   connect to them.
3. Use the **power switch**, adjust **Brightness**, or adjust **Temperature**. The first
   edit connects to that light, reads its actual state, applies the requested
   setting, and verifies the result. Other lights remain untouched.

You do **not** need to connect the light in System Settings first. It can appear
there under Nearby Devices without a Connect button; the app establishes its
own BLE connection when you use a control.

Each light has a compact header with power controls and two single-line sliders:
the sun icon is brightness, and the thermometer is color temperature. Hover for
labels. The panel chooses a compact viewport when opened and keeps its size and
position fixed until closed. Status messages have reserved space, so editing,
readback, and errors cannot move the sliders or reposition the window. Lights
that appear while it is open use the existing scroll area. Reopening can choose
a different viewport for the current number of lights; long lists always scroll.

The UI distinguishes the values being shown from the connection itself:

- **Not connected:** `—` readouts and **Unknown** beside the power switch.
  A standard switch has no indeterminate position: its initial Off position and
  the slider thumbs are placeholders, **not measured values**. Switching it On
  explicitly requests On and connects; adjusting a slider instead reads power
  without changing it. Accessibility descriptions also say the state is unknown.
- **Last known · Offline:** previous readings, explicitly not current state. Adjust a
  control to reconnect; an error explanation remains available.
- **Not applied / Connecting… / Verifying…:** previews and in-flight edits are
  labeled unverified until readback succeeds.
- **Verified:** values read from the light. Routine background refreshes do not
  change this label or the presentation of the previous reading.

Controls use their standard system appearance and accent color, with no custom
styles, desaturation, or operation-dependent opacity. The switch has its normal
On/Off appearance; connecting or verifying does not add a disabled-state flash.
Pointer input is gated while busy, and the model rejects overlapping keyboard or
accessibility edits and refreshes the bindings without queuing commands. Status
text and accessibility descriptions communicate unread, pending, or stale values.
Temperature uses the light's reported limits in 100 K steps; a first edit outside
those limits is rejected without sending a setting command.

A short, unique identifier suffix appears only when lights share a name. Hover
over a light's name for its full CoreBluetooth UUID. Multiple lights retain
independent state and command queues.
Click outside the panel or press **Escape** to dismiss it. **⌘Q** quits while
the app is active; Quit is also available in its standard application menu.
There is no Dock icon or separate control window.

## Discovery and on-demand connection

- While the panel is open, CoreBluetooth listens for advertisements using
  `scanForPeripherals(withServices:options:)`. Closing it stops scanning to save
  energy. There is no manual scan or connection workflow.
- The Air advertises the `1812` HID service, rather than its `FFF0` control
  service. Discovery checks the `YLight` name and the seven-byte `AAAB` service
  data containing its packet identity.
- `retrieveConnectedPeripherals(withServices:)` also contributes matching lights
  that stopped advertising because they are already connected. The two sources
  are deduplicated and ordered by identifier, not changing signal strength.
- System connections are refreshed about every three seconds. Unconnected
  advertisements expire after 30 seconds without another sighting. A pending
  local attachment keeps its row while the operation completes or times out.
- Discovery, opening the panel, and background polling never call `connect`.
  Only an explicit control edit does. No stored identifiers are used to reconnect
  lights, and failed settings are never automatically replayed.

CoreBluetooth does not provide a public list of all nearby devices seen by
System Settings. Advertisement scanning is necessary to find unconnected lights;
it does not establish a GATT connection or change light settings. A powered-off,
out-of-range, or nonadvertising unconnected device cannot be discovered this way.

Bluetooth **permission**, BLE **connection**, and **pairing/bonding** are different:
macOS may ask for app Bluetooth permission when discovery begins, and may request
pairing if a peripheral requires it. A connection does **not** guarantee an
acceptance or pairing prompt. The verified Air did not require an explicit
pairing step. The app relies on CoreBluetooth/system prompts rather than creating
its own pairing UI.

Apple also requires the app's own `connect(_:options:)` call before GATT access
to peripherals already connected by another app; see
[`retrieveConnectedPeripherals(withServices:)`](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:)).

## State and command safety

Commands require both the CoreBluetooth UUID and a six-byte packet identity.
Advertising lights provide that identity without a connection. If an unfamiliar
system-connected light no longer advertises, the app attempts to learn a candidate
from its captured Air `A4` notification envelope **after a user operates a control**.
This fallback has fixture coverage but is not guaranteed for every firmware or
attachment. If identity recovery fails, no setting is sent and the row explains
the error; the user can explicitly retry.

The first control action reads checksum-valid power, brightness, temperature,
and range replies before sending its setting command. Every setting is then
verified by readback. Slider edits are debounced for 300 ms after editing ends,
so rapid keyboard/accessibility adjustments coalesce and mouse drags never connect
or apply before release. Controls for that light reject
further input while its operation is in progress, without changing their drawing
style; other lights remain independent.

After successful first use, the app holds that light's connection and refreshes
status about every five seconds while idle. After a disconnect, it retains the
last read values when available, shows an explanation, and waits for another
explicit edit before reconnecting. Removing a light cancels unsent edits. The
hardware power switch must stay on for Bluetooth access; the app's Off command
controls light output rather than the radio.

Device identities and state are held only in memory. The old
`peripheralIdentifier` and `packetIdentity` preferences are not read or written.
Quitting releases the app's local GATT sessions, not other apps' sessions. If it
was the last owner, macOS may also close the physical connection.

Avoid other apps actively sending commands to the same light: replies use
sequence `FFFF` instead of echoing the request, so concurrent controllers are
ambiguous. A GATT write acknowledgement alone is never treated as success.

## Build

Requires macOS 14 or newer and Swift 6 or newer, provided by current Xcode Command
Line Tools or Xcode. There are no third-party Swift dependencies.

From the repository root:

```sh
./macos/build-app.sh
open 'build/YoloLight Air.app'
```

This builds for the current machine's architecture and creates an ad-hoc-signed
`build/YoloLight Air.app`. Quit an older running copy before rebuilding. Build
outputs are ignored by Git; the app may be moved to `~/Applications` afterward.

This local-build bundle is **not notarized or Developer ID signed**. The
[one-command release workflow](RELEASING.md) uses the same free ad-hoc signing by
default, and can publish the archive and Homebrew cask with
`python3 macos/release.py --publish`. No paid Apple account is required; Developer
ID signing/notarization remains optional. Do not disable Gatekeeper or Bluetooth
privacy protections.

`build-app.sh` also accepts an optional output `.app` path. The release tool uses
this to build an isolated bundle without replacing a running local app.

## Tests and validation scope

```sh
cd macos
swift test --disable-xctest
```

If the local Command Line Tools cannot find `TestingMacros`, explicitly add the
installed toolchain's testing plugin directory:

```sh
plugins="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing"
swift test --disable-xctest -Xswiftc -plugin-path -Xswiftc "$plugins"
```

An opt-in AppKit regression test briefly displays a window and popover in a
logged-in macOS GUI session. It asserts that the popover's actual screen origin
and size remain unchanged across model-driven temperature/brightness drags,
status changes, errors, and discovery updates. It uses simulated lights, not
Bluetooth, and does not depend on SwiftUI's private control classes:

```sh
YOLOLIGHT_UI_TESTS=1 swift test --disable-xctest --filter PopoverGeometryTests
```

Add the testing-plugin flags above if required by the toolchain.

Release-tool tests use Python 3.11+ and stub all external build/signing tools:

```sh
# From the repository root:
python3 -B -m unittest discover -s macos -p 'test_release*.py'
```

They validate final-archive checksums, cask generation, version/architecture
requirements, publication ordering, retries, and failure safety without accessing
signing keys, Apple, or GitHub. Git checks use isolated synthetic repositories.

Offline tests use synthetic identities and fake transports/discovery sources.
They cover advertisement validation, source merging/deduplication, stale device
expiry, radio resets, zero connections during discovery, connect-on-first-edit,
initial status validation before writing, readback verification, multiple
independent lights, cancellation, failures without automatic retries, and slider
release/debounce behavior. Presentation tests distinguish unread, stale, proposed,
in-flight, and verified values, including unknown power-switch state,
accessibility descriptions, unique short device labels, and binding updates for
rejected busy edits. They do not contact hardware or personal preferences.

Live single-light validation confirmed advertisement discovery with zero local
control sessions, enabled controls before connecting, and successful connection
and verified status after the user operated the controls. No identifiers or
packet captures are included in the project. Multiple physical lights and the
announcement-only identity fallback remain unverified on hardware. Power-off
transitions are not claimed as hardware-tested. Earlier Python controller tests
are documented in the [root README](../README.md).

## Design conventions

UI changes follow Apple's [macOS design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos).
The panel uses standard SwiftUI switches and sliders, SF Symbols, system fonts/colors,
accessible per-device groups, explicit unread/stale/unverified states, and a
scrolling panel whose geometry stays fixed while open. No custom connection
dialog, setup window, or animation demands attention.

## Source layout

- `Sources/LightCore/`: packet codec, advertisement/announcement identity parsing, and verified controller.
- `Sources/YoloLightMenu/BluetoothLights.swift`: discovery and user-triggered connection management.
- `Sources/YoloLightMenu/LightInventory.swift`: in-memory advertisement/system-state merge and expiry.
- `Sources/YoloLightMenu/BluetoothTransport.swift`: per-light GATT transport.
- `Sources/YoloLightMenu/LightsModel.swift`: multi-light lifecycle and panel discovery scope.
- `Sources/YoloLightMenu/LightModel.swift`: lazy connection, edits, and verified state.
- `Sources/YoloLightMenu/LightPresentation.swift`: state-validity labels, hints, and accessibility context.
- `Sources/YoloLightMenu/ControlPanel.swift`: standard SwiftUI switches, sliders, labels, and layout.
- `Sources/YoloLightMenu/App.swift`: application lifecycle and system menu-bar integration.
- `Sources/YoloLightMenu/LightPopover.swift`, `PanelLayout.swift`: fixed-per-presentation window and row geometry.
- `Tests/`: offline protocol, discovery, and multi-light tests.
- `Support/Info.plist`: menu-bar-only metadata and Bluetooth privacy description.
- `build-app.sh`: builds and bundles the app with the BSD 3-Clause license.
- `release.py`, `RELEASING.md`: one-command release preparation/publication, free ad-hoc signing by default.
- `Support/yololight-air.rb.in`: template for the generated root-level Homebrew cask.
- `test_release*.py`: offline packaging/publication tests and isolated Git regression tests.

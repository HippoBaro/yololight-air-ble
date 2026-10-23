"""Resolve a BLE peripheral through discovery or supported backend caches."""
import sys
from bleak import BleakScanner
from bleak.backends.device import BLEDevice

IDENTITY_SERVICE = "0000aaab-0000-1000-8000-00805f9b34fb"


async def scan_lights(timeout: float = 15) -> list[dict]:
    """List advertising lights and their packet identities without connecting."""
    if not 0 < timeout < float("inf"):
        raise ValueError("Scan timeout must be finite and greater than zero")
    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)
    lights = []
    for device, adv in devices.values():
        name = adv.local_name or device.name
        if name != "YLight":
            continue
        identity = adv.service_data.get(IDENTITY_SERVICE, b"")
        if len(identity) != 7 or identity[0] != 0xff:
            continue
        lights.append({
            "name": name,
            "address": device.address,
            "mac": identity[1:].hex(),
            "rssi": adv.rssi,
        })
    return sorted(lights, key=lambda light: (-light["rssi"], light["address"]))


async def find_light(address: str, timeout: float = 15) -> BLEDevice:
    if sys.platform == "darwin":
        from bleak.backends.corebluetooth.CentralManagerDelegate import CentralManagerDelegate
        from Foundation import NSUUID
        identifier = NSUUID.alloc().initWithUUIDString_(address)
        if identifier is None:
            raise ValueError("This Bluetooth backend requires --address to be a peripheral UUID")
        manager = CentralManagerDelegate()
        await manager.wait_until_ready()
        peripherals = manager.central_manager.retrievePeripheralsWithIdentifiers_([identifier])
        if peripherals:
            peripheral = peripherals[0]
            return BLEDevice(address, peripheral.name(), (peripheral, manager))
    device = await BleakScanner.find_device_by_address(address, timeout=timeout)
    if device is None:
        raise RuntimeError("YLight not found")
    return device

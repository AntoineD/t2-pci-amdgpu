# USB device not detected on plug (T2 xHCI autosuspend)

## Symptom

USB device (e.g. USB-to-Ethernet adapter) plugged in but does not appear in
`lsusb`. No `new device` event in `journalctl -k`. The xHCI root hub never
reports the attach.

## Cause

T2 Mac xHCI root hubs autosuspend aggressively. Once suspended, port-status
change notifications can stop reaching the host, so attach events are lost
until the hub is woken.

Manual wake confirms the diagnosis:

```bash
echo on | sudo tee /sys/bus/usb/devices/usb3/power/control
echo on | sudo tee /sys/bus/usb/devices/usb4/power/control
```

The device shows up immediately after.

## Fix (shipped)

`99-t2-usb.rules` pins all Linux virtual root hubs (`idVendor=0x1d6b`, hub
class `0x09`) to `power/control=on` at bind time. Downstream devices keep
their own autosuspend.

```
ACTION=="add", SUBSYSTEM=="usb", \
  ATTR{idVendor}=="1d6b", ATTR{bDeviceClass}=="09", \
  ATTR{power/control}="on"
```

## Related but not addressed

USB HID stalls when other USB activity occurs (mouse freeze on thumb-drive
plug). Likely same family of autosuspend-resume timing bug but on
non-root-hub HID interfaces. If the root-hub pin does not also fix this,
add a HID-targeted rule (match `bInterfaceClass==03` on the parent USB
device, write `power/control=on` to the parent).

## References

- https://www.kernel.org/doc/html/latest/driver-api/usb/power-management.html
- https://wiki.t2linux.org/

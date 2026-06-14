# Tcl BLE Library for OSX

A Bluetooth Low Energy `ble` command for **Tcl/Tk on macOS**, API-compatible with
[AndroWish](https://www.androwish.org/)'s built-in `ble` command.

AndroWish and undroidwish ship a `ble` command on Android and Linux, but **macOS
has none** — so Tcl code written against the AndroWish BLE API (for example the
[Decent Espresso `de1app`](https://github.com/decentespresso/de1app)) can't talk
to Bluetooth devices there. This library fills that gap using Apple's
CoreBluetooth, so that code runs unmodified on the Mac.

It works under **standard Aqua `wish`** *and* **undroidwish**, and has been
verified end-to-end against a real Decent Espresso DE1 machine and an Atomax
Skale scale: scan, connect, service/characteristic discovery, notification
enable + ACK, live notifications, and reads.

```tcl
package require ble

proc cb {event data} {
    if {$event eq "scan"} {
        puts "[dict get $data rssi] dBm  [dict get $data name]  [dict get $data address]"
    }
}
ble scanner cb        ;# start scanning; cb fires for every device
```

## How it works

```
  your Tcl  ──ble scanner/connect/enable/write/read──▶  ble.tcl  (this package)
                                                            │  line protocol over a stdio pipe
                                                            ▼
                                                      bin/ble_helper  (Swift / CoreBluetooth)
                                                            │
                                                            ▼
                                                       macOS Bluetooth
```

- **`ble.tcl`** installs the `ble` command and re-emits CoreBluetooth activity as
  the exact AndroWish event dictionaries (`scan`, `connection`, `characteristic`,
  `descriptor`), invoking your callback as `{*}$callback $event $datadict`.
- **`bin/ble_helper`** is a small **universal** (arm64 + x86_64) Swift binary that
  owns the CoreBluetooth central manager and speaks a tab-separated line protocol
  on stdin/stdout. The Tcl side spawns it with `open |...`.

A separate process (rather than a loadable Tcl extension) keeps the library
independent of the interpreter's architecture and stubs version — important
because undroidwish on macOS is an x86_64 binary with an appended VFS, while
modern Macs are arm64.

### Two macOS realities it handles for you

1. **No MAC addresses.** CoreBluetooth never exposes a peripheral's hardware
   address; it uses an opaque, host-stable `NSUUID`. The library uses that UUID
   string as the "address" you scan, store, and reconnect with. It is stable
   across launches for a given Mac + peripheral pair.

2. **Bluetooth permission (TCC).** macOS attributes a Bluetooth request to the
   "responsible" app. Unsigned interpreters (like undroidwish) can't satisfy
   that, so the prompt never completes. The helper works around this by
   **re-spawning itself with responsibility inheritance disclaimed**
   (`responsibility_spawnattrs_setdisclaim`), making it its *own* responsible
   process. macOS then evaluates the helper's own signature + embedded
   `NSBluetoothAlwaysUsageDescription` and shows a normal prompt — **no changes
   to the host interpreter or app are needed.** You approve it once and the grant
   persists.

## Install

Requires the Xcode command-line tools (`swiftc`).

```bash
git clone https://github.com/johnbuckman/tcl-ble-osx
cd tcl-ble-osx
./build.sh            # builds + ad-hoc-signs bin/ble_helper (universal)
```

Then put the directory on `auto_path` and require it:

```tcl
lappend auto_path /path/to/tcl-ble-osx
package require ble
```

A prebuilt `bin/ble_helper` is included, but rebuilding locally is recommended so
the Bluetooth grant binds to a signature you control.

## Examples

| File | What it does |
|------|--------------|
| [`examples/scan.tcl`](examples/scan.tcl) | List nearby BLE devices for 15 s |
| [`examples/skale.tcl`](examples/skale.tcl) | Connect to an Atomax **Skale**, stream weight, tare |
| [`examples/de1.tcl`](examples/de1.tcl) | Monitor a Decent Espresso **DE1**'s machine state (read-only) |

Run any of them with standard Aqua wish:

```bash
/usr/local/bin/wish8.6 examples/scan.tcl
```

### Skale example

Scans for an Atomax Skale, connects, enables weight notifications, shows the
weight on the scale's LCD, and tares it after a few seconds (demonstrating a
write). Weight notifications are a flag byte followed by a signed little-endian
int16 in tenths of a gram:

```tcl
package require ble

set SUUID   0000FF08-0000-1000-8000-00805F9B34FB   ;# Skale service
set CMD     0000EF80-0000-1000-8000-00805F9B34FB   ;# write: tare / LCD / timer
set WEIGHT  0000EF81-0000-1000-8000-00805F9B34FB   ;# notify: weight

proc cb {event data} {
    switch -- $event {
        scan {
            if {!$::found && [string match -nocase "Skale*" [dict get $data name]]} {
                set ::found 1
                ble stop $::scanner
                set ::skale [ble connect [dict get $data address] cb 0]
            }
        }
        characteristic {
            if {[dict get $data state] eq "discovery"} {
                set ::sinstance([dict get $data suuid]) [dict get $data sinstance]
                set ::cinstance([dict get $data cuuid]) [dict get $data cinstance]
            } elseif {[dict get $data cuuid] eq $::WEIGHT} {
                binary scan [dict get $data value] xs raw          ;# skip flag, signed LE int16
                puts [format "%.1f g" [expr {$raw / 10.0}]]
            }
        }
        connection {
            if {[dict get $data state] eq "connected"} {
                ble enable $::skale $::SUUID $::sinstance($::SUUID) \
                           $::WEIGHT $::cinstance($::WEIGHT)
            }
        }
    }
}
set ::found 0
set ::scanner [ble scanner cb]
```

The full version (LCD display + tare write + a little UI) is in
[`examples/skale.tcl`](examples/skale.tcl).

## API

```
ble scanner   <callback>                          -> scanner token; starts scanning
ble stop      <token>                             -> stop scanning
ble connect   <address> <callback> ?<reconnect>?  -> connection handle (e.g. "ble1")
ble close     <handle>                            -> disconnect (or stop a scanner token)
ble info      ?<handle>?                           -> open handles / info for one
ble enable    <h> <suuid> <si> <cuuid> <ci>       -> 1; enable notifications
ble disable   <h> <suuid> <si> <cuuid> <ci>       -> 1
ble write     <h> <suuid> <si> <cuuid> <ci> ?<writetype>? <data>  -> 1
ble read      <h> <suuid> <si> <cuuid> <ci>       -> 1
ble mtu       <h> ?<value>?                         -> negotiated MTU
ble userdata  <h> ?<value>?                         -> per-handle scratch store
ble state                                           -> central manager state
```

Your callback is invoked as `{*}$callback $event $datadict`:

| `event` | `datadict` keys |
|---------|-----------------|
| `scan` | `address` `name` `rssi` |
| `connection` | `handle` `address` `state` (`connected`/`disconnected`), `mtu` on connect |
| `characteristic` (`state=discovery`) | `handle` `address` `suuid` `sinstance` `cuuid` `cinstance` |
| `characteristic` (`state=connected`) | `access` (`r` read / `w` write-ack / `c` notification), `value` (binary), `cuuid` … |
| `descriptor` (`state=connected access=w`) | the notification-enable (CCCD) acknowledgement |

`value` is a binary byte array; `name` is a string; `write` accepts the optional
Android write-type (`1` = no response, `2` = default).

The `sinstance`/`cinstance` integers are assigned during discovery and echoed
back in the discovery events; store them (keyed by UUID, as the examples do) and
pass them to `enable`/`write`/`read`.

## Testing

```bash
/usr/local/bin/wish8.6 test/test_ble.tcl     # scan + connect + enable + read
```

`test/build_testapp.sh` wraps an interpreter + this library + the test into a
launchable `.app`, which is handy when the interpreter itself can't be
code-signed (e.g. undroidwish) and you need the Bluetooth prompt to appear.

## Notes

- **First run** shows a one-time macOS Bluetooth prompt. Approve it; the grant
  persists (keyed to the helper's code signature, so rebuilding re-prompts).
- For distribution, sign `bin/ble_helper` with a Developer ID and notarize the
  containing app so the grant is stable and Gatekeeper-friendly. The embedded
  `Info.plist` must keep `NSBluetoothAlwaysUsageDescription`.
- `BLE_HELPER_NO_REEXEC=1` disables the self-disclaim (debugging); then TCC falls
  back to the launching app's identity.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

Built to bring the Decent Espresso `de1app` to macOS; usable by any Tcl program
that wants Bluetooth LE on the Mac.

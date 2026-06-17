# Tcl BLE Library for OSX

A Bluetooth Low Energy `ble` command for **Tcl/Tk on macOS**, API-compatible with
[AndroWish](https://www.androwish.org/)'s built-in `ble` command.

AndroWish and undroidwish ship a `ble` command on Android and Linux, but **macOS
has none** — so Tcl code written against the AndroWish BLE API (for example the
[Decent Espresso `de1app`](https://github.com/decentespresso/de1app)) can't talk
to Bluetooth devices there. This library fills that gap using Apple's
CoreBluetooth, so that code runs unmodified on the Mac.

It works under **plain `tclsh`** (no Tk), **standard Aqua `wish`**, *and*
**undroidwish**, and has been verified end-to-end against a real Decent Espresso
DE1 machine and an Atomax Skale scale: scan, connect, service/characteristic
discovery, notification enable + ACK, live notifications, and reads.

```tcl
package require ble

proc cb {event data} {
    if {$event eq "scan"} {
        puts "[dict get $data rssi] dBm  [dict get $data name]  [dict get $data address]"
    }
}
ble scanner cb        ;# start scanning; cb fires for every device
vwait forever         ;# in a script (or tclsh) you must run the event loop
```

> **Heads-up:** BLE is asynchronous, so your callback only fires while Tcl's
> event loop is running. `wish`/undroidwish enter it automatically once the
> script finishes, but **`tclsh` does not** — in a script end with
> `vwait forever` (or `vwait somevar`), and at an interactive `tclsh` prompt run
> `vwait forever` (Ctrl-C to stop) after `ble scanner`, otherwise nothing prints.

## How it works

`ble.tcl` installs the `ble` command and presents the AndroWish event
dictionaries (`scan`, `connection`, `characteristic`, `descriptor`), invoking
your callback as `{*}$callback $event $datadict`. Underneath, it has **two
interchangeable backends** and picks the best one automatically:

```
  your Tcl ──ble …──▶ ble.tcl ──┬─▶ lib/libtclble.<dylib>   (in-process extension)  ─▶ CoreBluetooth
                                │       used by default when Bluetooth works in-process
                                └─▶ bin/ble_helper           (subprocess, Swift)      ─▶ CoreBluetooth
                                        fallback that works everywhere
```

- **Native extension — `lib/libtclble.<dylib>`** (built from `native/tclble.m`).
  A loadable Tcl extension that drives CoreBluetooth **in-process**. Lowest
  overhead, and the **only** option on iOS (iWish), where spawning a subprocess
  isn't allowed.
- **Subprocess helper — `bin/ble_helper`** (universal arm64 + x86_64, built from
  `ble_helper.swift`). Speaks a tab-separated line protocol over a stdio pipe.

**Why two?** A loadable extension runs *inside* the interpreter, so its
Bluetooth access takes on the **interpreter's** TCC identity. That's fine for a
signed app (or iOS), but an unsignable host like undroidwish can't get Bluetooth
that way — and an in-process attempt there can even wedge. The helper sidesteps
this: it re-spawns itself with **responsibility disclaimed**, becoming its *own*
TCC identity, so it works under any host. It's also architecture- and
stubs-independent.

**Backend selection (safe by default).** `ble.tcl` uses the **subprocess
helper by default** — it works on every interpreter (tclsh, undroidwish, signed
or not), so you never have to set anything to avoid a crash. The native
in-process extension is **opt-in only**: set **`BLE_USE_NATIVE=1`** from a host
that can legitimately hold Bluetooth in-process (a signed app whose Info.plist
carries `NSBluetoothAlwaysUsageDescription`). This is deliberate: loading the
native dylib in a host *without* a usage description (plain tclsh, the
unsignable undroidwish) makes macOS TCC abort the whole process with an
**uncatchable SIGABRT** the instant it touches CoreBluetooth — so the library
must never load it unasked. `BLE_NO_NATIVE=1` still forces the helper (now the
default, kept for backward compatibility). Both backends expose the identical
`ble` API.

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

A prebuilt `bin/ble_helper` is included, but rebuilding locally is recommended so
the Bluetooth grant binds to a signature you control.

`package require ble` only finds the package if its directory is on Tcl's
`auto_path`. Pick whichever of the following fits — **always move the whole
directory**, because the package locates `bin/ble_helper` relative to `ble.tcl`.

### Adding it to your existing Tcl / undroidwish installation

**Option A — one line in your script (no install).** Works everywhere; good for
a self-contained app:

```tcl
lappend auto_path /Users/you/tcl-ble-osx
package require ble
```

**Option B — an environment variable (no copying).** Tcl prepends `TCLLIBPATH`
to `auto_path` at startup, so `package require ble` then works in **both `tclsh`
and `undroidwish`** with no code change. Add to `~/.zshrc` / `~/.bashrc`:

```bash
export TCLLIBPATH=/Users/you/tcl-ble-osx
```

(`TCLLIBPATH` is a space-separated list if you have several package dirs.)

**Option C — install it once for everything (recommended).** `/usr/local/lib`
is on the `auto_path` of *both* the system `tclsh`/`wish` and `undroidwish`, so a
single symlink there makes `package require ble` work everywhere, no config:

```bash
ln -s /Users/you/tcl-ble-osx /usr/local/lib/tcl-ble-osx
# (use `cp -R` instead of `ln -s` if you prefer a copy)
```

**Option D — `tclsh`/`wish` only.** macOS Tcl also scans `~/Library/Tcl`:

```bash
mkdir -p ~/Library/Tcl
ln -s /Users/you/tcl-ble-osx ~/Library/Tcl/tcl-ble-osx
```

Verify any of the above:

```bash
echo 'puts [package require ble]; exit' | tclsh      # prints 1.0
```

### Using it from `tclsh`

It works in headless `tclsh` exactly as in `wish` — just remember the event-loop
note above. A complete scanner script:

```tcl
package require ble
proc cb {event data} {
    if {$event eq "scan"} {
        puts "[dict get $data rssi] dBm  [string trim [dict get $data name]]  [dict get $data address]"
    }
}
ble scanner cb
after 15000 {exit}     ;# scan 15 s then quit
vwait forever          ;# <-- run the event loop so cb actually fires
```

The first run shows the one-time macOS Bluetooth prompt (attributed to the
helper); approve it and the grant persists.

## Integrating into an existing AndroWish app

Apps written for AndroWish (like the Decent Espresso `de1app`) often detect a
working Bluetooth stack with `catch { package require ble }`, then gate features
on an `$::android` flag because, historically, only Android had real BLE. Three
things to watch for when adding this package so those apps "just work" on macOS:

1. **Make `package require ble` find it.** Put this directory on `auto_path`
   (or add a `package ifneeded ble 1.0 [list source .../ble.tcl]` line) before
   the app's BLE-detection runs.

2. **Don't let an Android-stub clobber the real `ble`.** AndroWish apps commonly
   define a no-op `proc ble {args} { return 1 }` as part of stubbing Android-only
   APIs on desktop — and if that runs *after* this package loads, it silently
   replaces the real command, so every `ble scanner`/`ble start` becomes a no-op
   that returns `1` and never scans. Guard any such stub:

   ```tcl
   if {[llength [info commands ble]] == 0} {
       proc ble {args} { ... }      ;# only stub when there is no real one
   }
   ```

3. **Broaden Android-only feature gates.** Replace `$::android == 1` BLE gates
   with a "real BLE is present" test so they also fire on macOS (and iOS/iWish).
   Compute it once, right after `package require ble` and *before* any `ble`
   stub could be defined:

   ```tcl
   set ::has_bluetooth [expr {[llength [info commands ble]] > 0}]
   # then: `$::android == 1`  -> `$::has_bluetooth`
   #       `$::android != 1`  -> `!$::has_bluetooth`
   ```

   On macOS, run the app as "undroid" (not "android") so its Android-only APIs
   (`borg`, etc.) still get stubbed, while keeping this real `ble` command.

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

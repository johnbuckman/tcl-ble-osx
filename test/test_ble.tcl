# test_ble.tcl --
#
# Exercises the macOS "ble" package the way the de1app does:
#   * loads the package (so `package require ble` works)
#   * starts a scanner and logs every AndroWish-style event
#   * if a DE1 / Decent Scale / other known scale shows up, connects to it,
#     logs service/characteristic discovery, and enables notifications
#
# All activity is written to RESULTFILE so it can be inspected headlessly.
# A tiny Tk window shows live progress.  The script exits on its own.
#
# Run standalone:  wish test_ble.tcl
# (but Bluetooth permission only works inside a .app that declares
#  NSBluetoothAlwaysUsageDescription -- see build_testapp.sh)

set RESULTFILE "/tmp/ble_test_result.txt"
set SCAN_SECONDS 10
set TOTAL_SECONDS 26

# --- locate and load the package -------------------------------------------
set here [file dirname [file normalize [info script]]]
lappend auto_path [file join $here ble]
lappend auto_path $here

set ::logfh [open $RESULTFILE w]
proc LOG {args} {
    set line [join $args " "]
    set stamp [clock format [clock seconds] -format %H:%M:%S]
    puts $::logfh "$stamp  $line"
    flush $::logfh
    catch { .status configure -text $line }
    catch { puts "$stamp  $line" }
}

if {[catch {package require ble} err]} {
    LOG "FAIL: package require ble -> $err"
    after 1500 exit
    return
}
LOG "OK: package require ble  (version [package present ble])"

# --- minimal GUI -----------------------------------------------------------
catch {
    wm title . "DE1 macOS BLE test"
    # BLE_TEST_GEOM lets the launcher place the window on a chosen display,
    # e.g. "720x140+-1900+600" puts it on a built-in laptop screen left of main.
    set _geom [expr {[info exists ::env(BLE_TEST_GEOM)] ? $::env(BLE_TEST_GEOM) : "720x140"}]
    wm geometry . $_geom
    label .status -text "starting..." -anchor w -justify left -wraplength 700
    label .count  -text "" -anchor w
    pack .status -fill x -padx 12 -pady {16 4}
    pack .count  -fill x -padx 12
}

# --- counters / discovered devices -----------------------------------------
set ::n_scan 0
set ::n_char 0
set ::devices [dict create]      ;# address -> name
set ::connected 0
set ::connect_handle 0
set ::target_address ""
set ::enabled_once 0

proc update_count {} {
    catch { .count configure -text \
        "scan events: $::n_scan   devices: [dict size $::devices]   char-discovery: $::n_char" }
}

# --- the BLE callback (same signature the de1app uses) ---------------------
proc cb {event data} {
    switch -- $event {
        scan {
            incr ::n_scan
            set addr [dict get $data address]
            set name [expr {[dict exists $data name] ? [dict get $data name] : ""}]
            set rssi [expr {[dict exists $data rssi] ? [dict get $data rssi] : "?"}]
            if {![dict exists $::devices $addr]} {
                dict set ::devices $addr $name
                LOG "SCAN new device  rssi=$rssi  name='[string trim $name]'  addr=$addr"
            }
            # Pick the first interesting peripheral to connect to.
            if {$::target_address eq ""} {
                set up [string toupper $name]
                if {[string match "DE1*" $up] || [string match "BENGLE*" $up] \
                    || [string match "*DECENT SCALE*" $up] || [string match "*SKALE*" $up] \
                    || [string match "*ACAIA*" $up] || [string match "*FELICITA*" $up] \
                    || [string match "*BOOKOO*" $up] || [string match "*PYXIS*" $up] \
                    || [string match "*LUNAR*" $up]} {
                    set ::target_address $addr
                    LOG "TARGET selected for connect test: '[string trim $name]' $addr"
                    after 200 try_connect
                }
            }
            update_count
        }
        connection {
            set state [dict get $data state]
            set h [expr {[dict exists $data handle] ? [dict get $data handle] : "?"}]
            LOG "CONNECTION  handle=$h  state=$state [expr {[dict exists $data mtu] ? "mtu=[dict get $data mtu]" : ""}]"
            if {$state eq "connected"} {
                set ::connected 1
                # Enable notifications on a couple of discovered characteristics
                # to exercise the enable -> descriptor-ACK path.
                after 300 enable_some
            }
        }
        characteristic {
            set state [dict get $data state]
            if {$state eq "discovery"} {
                incr ::n_char
                LOG "  CHAR discovery  suuid=[dict get $data suuid]  cuuid=[dict get $data cuuid]  sinst=[dict get $data sinstance]  cinst=[dict get $data cinstance]"
                update_count
            } else {
                set access [expr {[dict exists $data access] ? [dict get $data access] : "?"}]
                set val [expr {[dict exists $data value] ? [binary encode hex [dict get $data value]] : ""}]
                LOG "  CHAR $access  cuuid=[dict get $data cuuid]  value=$val"
            }
        }
        descriptor {
            LOG "  DESC [dict get $data access] cuuid=[dict get $data cuuid] (notification ACK)"
        }
        default {
            LOG "EVENT $event $data"
        }
    }
}

proc try_connect {} {
    if {$::connect_handle != 0 || $::target_address eq ""} return
    # Use cb_record so discovery rows are captured for the enable step.
    set ::connect_handle [ble connect $::target_address cb_record 0]
    LOG "ble connect $::target_address -> handle $::connect_handle"
}

# Enable notifications on every discovered characteristic that supports it.
# We just walk the cinstance map the de1app would build; here we keep our own
# from the discovery events.
set ::disc_chars {}    ;# list of {handle suuid sinst cuuid cinst}
proc enable_some {} {
    if {$::enabled_once} return
    set ::enabled_once 1
    # Device-agnostic: enable notifications on every discovered characteristic
    # (non-mutating) to exercise enable -> descriptor 'w' ACK and the resulting
    # notification -> characteristic 'c' values.  Then read the first one.
    set n 0
    foreach c $::disc_chars {
        lassign $c h suuid sinst cuuid cinst
        if {[catch { set r [ble enable $h $suuid $sinst $cuuid $cinst] } e] == 0} {
            LOG "ble enable $cuuid -> $r  (expect a descriptor 'w' ACK)"
            incr n
        }
    }
    LOG "requested enable on $n characteristics"
    if {[llength $::disc_chars] > 0} {
        lassign [lindex $::disc_chars 0] h suuid sinst cuuid cinst
        catch {
            set r [ble read $h $suuid $sinst $cuuid $cinst]
            LOG "ble read $cuuid -> $r  (expect a characteristic 'r' value)"
        }
    }
}

# Capture discovery rows for the enable step.
proc cb_record {event data} {
    if {$event eq "characteristic" && [dict get $data state] eq "discovery"} {
        lappend ::disc_chars [list [dict get $data handle] [dict get $data suuid] \
            [dict get $data sinstance] [dict get $data cuuid] [dict get $data cinstance]]
    }
    cb $event $data
}

# --- run -------------------------------------------------------------------
LOG "ble state = [ble state]"
LOG "starting scanner for $SCAN_SECONDS s ..."
set ::scanner [ble scanner cb_record]
LOG "scanner token = $::scanner"

after [expr {$SCAN_SECONDS * 1000}] {
    catch { ble stop $::scanner }
    LOG "scan stopped. total devices seen: [dict size $::devices]"
    if {[dict size $::devices] == 0} {
        LOG "NOTE: no BLE devices seen. If Bluetooth is on and devices are nearby,"
        LOG "      check that the Bluetooth permission prompt was approved."
    }
}

after [expr {$TOTAL_SECONDS * 1000}] {
    LOG "=== TEST COMPLETE ==="
    LOG "summary: scan_events=$::n_scan devices=[dict size $::devices] char_discovery=$::n_char connected=$::connected"
    foreach {addr name} $::devices {
        LOG "  device: $addr  '[string trim $name]'"
    }
    catch { foreach h [ble info] { ble close $h } }
    flush $::logfh
    after 800 exit
}

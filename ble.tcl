# ble.tcl --
#
# Tcl BLE Library for OSX -- https://github.com/johnbuckman/tcl-ble-osx
# Copyright (C) 2026 John Buckman
# SPDX-License-Identifier: GPL-3.0-or-later
#
# An AndroWish-compatible `ble` command for undroidwish on macOS.
#
# AndroWish (and undroidwish on Linux) ship a built-in `ble` command backed by
# the platform Bluetooth stack.  macOS undroidwish has none, so this package
# provides a drop-in replacement implemented on top of Apple's CoreBluetooth via
# a small helper process (bin/ble_helper, built from ble_helper.swift).
#
# Loading this package as "ble" means the de1app's own probe
#     catch { package require ble }
# succeeds, so it treats the machine as having a working native BLE stack.
#
# The command surface and the callback event dictionaries match what the de1app
# expects from AndroWish:
#
#   ble scanner   <callback>                       -> scanner token (starts scan)
#   ble stop      <token>                          -> stop scanning
#   ble connect   <address> <callback> <reconnect> -> connection handle
#   ble close     <handle>                         -> disconnect / stop scanner
#   ble info      ?<handle>?                        -> list of handles / info
#   ble enable    <h> <suuid> <si> <cuuid> <ci>    -> enable notifications  (->1)
#   ble disable   <h> <suuid> <si> <cuuid> <ci>    -> disable notifications (->1)
#   ble write     <h> <suuid> <si> <cuuid> <ci> ?<writetype>? <data>   (->1)
#   ble read      <h> <suuid> <si> <cuuid> <ci>    -> request read          (->1)
#   ble mtu       <h> ?<value>?                     -> negotiated MTU
#   ble userdata  <h> ?<value>?                     -> per-handle scratch store
#   ble state                                       -> central manager state
#   ble abort / ble unpair / ble disconnect         -> accepted (no-op / close)
#
# The callback is invoked as:  {*}$callback $event $datadict
# with $event one of: scan connection characteristic descriptor
# and $datadict carrying the AndroWish keys (handle address name rssi state
# suuid sinstance cuuid cinstance duuid access value ...).  `value` is a binary
# byte array, `name` is a plain string; everything else is text.

package require Tcl 8.5

namespace eval ::bleosx {
    variable chan        ""
    variable cstate      "unknown"
    variable handleseq   0
    variable scannerseq  0
    variable scannercb   ""
    variable buf         ""

    variable cb            ;# handle -> callback
    variable addr          ;# handle -> address
    variable mtu           ;# handle -> negotiated mtu
    variable udata         ;# handle -> userdata scratch
    array set cb    {}
    array set addr  {}
    array set mtu   {}
    array set udata {}

    variable helper [file normalize [file join [file dirname [info script]] bin ble_helper]]
    variable debug 0      ;# set 1 to log helper diagnostics to the de1app logger
}

# Optional diagnostics -> the de1app logger (DEBUG level).  Off by default.
proc ::bleosx::log {args} {
    variable debug
    if {!$debug} return
    set m [join $args " "]
    catch {
        if {[llength [info commands ::msg]]}  { ::msg -DEBUG "ble_osx: $m" } \
        elseif {[llength [info commands msg]]} { msg  -DEBUG "ble_osx: $m" }
    }
}

# ---------------------------------------------------------------------------
# Helper process lifecycle
# ---------------------------------------------------------------------------

proc ::bleosx::ensure_helper {} {
    variable chan
    variable helper
    if {$chan ne "" && ![catch {fconfigure $chan}]} {
        return
    }
    if {![file executable $helper]} {
        error "unsupported"  ;# de1app treats this as "Bluetooth is not on"
    }
    # NB: no "2>@stderr" -- undroidwish's stderr is a console channel that can't
    # be an exec redirect target.  The helper inherits our stderr instead.
    if {[catch {open "|[list $helper]" r+} ch]} {
        error "unsupported"
    }
    fconfigure $ch -blocking 0 -buffering line -translation lf -encoding utf-8
    fileevent $ch readable [list ::bleosx::on_readable $ch]
    set chan $ch
    log "helper spawned: $helper"
}

proc ::bleosx::send {args} {
    variable chan
    ensure_helper
    puts $chan [join $args "\t"]
    flush $chan
}

# ---------------------------------------------------------------------------
# Reading + dispatching events from the helper
# ---------------------------------------------------------------------------

proc ::bleosx::on_readable {ch} {
    variable chan
    if {[catch {gets $ch line} n]} {
        catch {close $ch}
        if {$ch eq $chan} { set chan "" }
        return
    }
    if {$n < 0} {
        if {[eof $ch]} {
            catch {close $ch}
            if {$ch eq $chan} { set chan "" }
        }
        return
    }
    dispatch_line $line
}

proc ::bleosx::dispatch_line {line} {
    variable cstate
    variable scannercb
    variable cb
    variable mtu

    set f [split $line "\t"]
    set tag [lindex $f 0]

    switch -- $tag {
        state {
            set cstate [lindex $f 1]
            return
        }
        LOG {
            # Route helper diagnostics to the de1app logger if present.
            set m [join [lrange $f 1 end] "\t"]
            log "helper: $m"
            return
        }
        EV {
            # fall through
        }
        default {
            return
        }
    }

    set event [lindex $f 1]
    set data [dict create]
    foreach kv [lrange $f 2 end] {
        set eq [string first "=" $kv]
        if {$eq < 0} continue
        set k [string range $kv 0 [expr {$eq - 1}]]
        set v [string range $kv [expr {$eq + 1}] end]
        switch -- $k {
            name    { dict set data name  [decode_text $v] }
            value   { dict set data value [binary decode hex $v] }
            address { dict set data address [string toupper $v] }
            default { dict set data $k $v }
        }
    }

    # Cache MTU as it arrives on the connection event.
    if {$event eq "connection" && [dict exists $data handle] && [dict exists $data mtu]} {
        set mtu([dict get $data handle]) [dict get $data mtu]
    }

    # Route to the right callback: handle-bearing events go to that handle's
    # callback; scan events go to the scanner callback.
    set callback ""
    if {[dict exists $data handle] && [info exists cb([dict get $data handle])]} {
        set callback $cb([dict get $data handle])
    } elseif {$event eq "scan"} {
        set callback $scannercb
    } elseif {$scannercb ne ""} {
        set callback $scannercb
    }
    if {$callback eq ""} return

    if {[catch {uplevel #0 [list {*}$callback $event $data]} err]} {
        catch {
            if {[llength [info commands ::bgerror]]} { ::bgerror $err } \
            else { puts stderr "ble callback error: $err\n$::errorInfo" }
        }
    }
}

proc ::bleosx::decode_text {hex} {
    return [encoding convertfrom utf-8 [binary decode hex $hex]]
}

# ---------------------------------------------------------------------------
# The `ble` command
# ---------------------------------------------------------------------------

proc ble {sub args} {
    return [::bleosx::cmd $sub {*}$args]
}

proc ::bleosx::cmd {sub args} {
    variable chan
    variable cstate
    variable handleseq
    variable scannerseq
    variable scannercb
    variable cb
    variable addr
    variable mtu
    variable udata

    switch -- $sub {

        scanner {
            # ble scanner <callback>
            ensure_helper
            set scannercb [lindex $args 0]
            incr scannerseq
            set token "blescanner$scannerseq"
            send scan start
            return $token
        }

        start {
            # ble start <token>   (begin scanning)
            # AndroWish separates `ble scanner` (create) from `ble start`
            # (begin).  Our `ble scanner` already starts; this is idempotent
            # so code that does scanner-then-start works either way.
            send scan start
            return ""
        }

        stop {
            # ble stop <token>     (stop scanning)
            send scan stop
            return ""
        }

        connect {
            # ble connect <address> <callback> ?<reconnect>?
            if {$cstate in {poweredOff unauthorized unsupported}} {
                error "unsupported"
            }
            ensure_helper
            set address [string toupper [lindex $args 0]]
            set callback [lindex $args 1]
            set reconnect [expr {[llength $args] >= 3 ? [lindex $args 2] : 0}]
            incr handleseq
            set handle "ble$handleseq"
            set cb($handle) $callback
            set addr($handle) $address
            send connect $handle $address $reconnect
            return $handle
        }

        close - disconnect {
            # ble close <handle>   (connection handle or scanner token)
            set handle [lindex $args 0]
            if {[string match "blescanner*" $handle]} {
                send scan stop
                return ""
            }
            if {[info exists cb($handle)]} {
                send close $handle
            }
            return ""
        }

        info {
            # ble info ?<handle>?
            if {[llength $args] == 0} {
                return [array names cb]
            }
            set handle [lindex $args 0]
            if {![info exists addr($handle)]} { return "" }
            return [list handle $handle address $addr($handle) \
                         mtu [expr {[info exists mtu($handle)] ? $mtu($handle) : 23}]]
        }

        enable {
            # ble enable <handle> <suuid> <sinstance> <cuuid> <cinstance>
            lassign $args handle suuid sinstance cuuid cinstance
            send enable $handle $cinstance
            return 1
        }

        disable {
            # ble disable <handle> <suuid> <sinstance> <cuuid> <cinstance>
            lassign $args handle suuid sinstance cuuid cinstance
            send disable $handle $cinstance
            return 1
        }

        write {
            # ble write <handle> <suuid> <sinst> <cuuid> <cinst> ?<writetype>? <data>
            set handle    [lindex $args 0]
            set cinstance [lindex $args 4]
            if {[llength $args] >= 7} {
                set writetype [lindex $args 5]
                set data      [lindex $args 6]
            } else {
                set writetype 2   ;# WRITE_TYPE_DEFAULT (with response)
                set data      [lindex $args 5]
            }
            send write $handle $cinstance $writetype [binary encode hex $data]
            return 1
        }

        read {
            # ble read <handle> <suuid> <sinstance> <cuuid> <cinstance>
            lassign $args handle suuid sinstance cuuid cinstance
            send read $handle $cinstance
            return 1
        }

        mtu {
            # ble mtu <handle> ?<value>?
            set handle [lindex $args 0]
            if {[info exists mtu($handle)]} { return $mtu($handle) }
            return 23
        }

        userdata {
            # ble userdata <handle> ?<value>?     (per-handle scratch store)
            set handle [lindex $args 0]
            if {[llength $args] >= 2} {
                set udata($handle) [lindex $args 1]
            }
            return [expr {[info exists udata($handle)] ? $udata($handle) : ""}]
        }

        state {
            return $cstate
        }

        abort - unpair - pair {
            return ""
        }

        default {
            error "ble: unknown subcommand \"$sub\""
        }
    }
}

# Spawn the helper eagerly so the CoreBluetooth permission prompt (if any)
# appears at startup and the central manager is warming up by the time the app
# calls `ble scanner` / `ble connect`.
catch { ::bleosx::ensure_helper }

package provide ble 1.0

# skale.tcl -- Atomax Skale weight example for the Tcl BLE Library for OSX.
#
# Scans for a Skale, connects, streams live weight, shows it on the scale's LCD,
# and sends a tare after a few seconds (to demonstrate writing).  Weight is
# printed to stdout and shown in a small window.
#
# Run:  /usr/local/bin/wish8.6 examples/skale.tcl
#       (or any AndroWish / undroidwish)
#
# SPDX-License-Identifier: GPL-3.0-or-later

set here [file dirname [file normalize [info script]]]
lappend auto_path [file join $here ..]        ;# the library dir (ble.tcl / pkgIndex.tcl)
package require ble

# --- Atomax Skale GATT ------------------------------------------------------
set SUUID   0000FF08-0000-1000-8000-00805F9B34FB   ;# Skale service
set CMD     0000EF80-0000-1000-8000-00805F9B34FB   ;# write: tare / LCD / timer
set WEIGHT  0000EF81-0000-1000-8000-00805F9B34FB   ;# notify: weight

set CMD_TARE            [binary decode hex 10]      ;# tare
set CMD_DISPLAY_WEIGHT  [binary decode hex EC]      ;# show weight on the LCD

# --- state ------------------------------------------------------------------
set ::skale  0
set ::found  0
array set ::sinstance {}
array set ::cinstance {}

# --- tiny UI ----------------------------------------------------------------
catch {
    wm title . "Skale"
    wm geometry . 320x120
    label .w -text "scanning..." -font {Helvetica 36} -anchor center
    pack .w -fill both -expand 1
}
proc show {txt} { puts $txt; catch { .w configure -text $txt } }

# --- BLE callback (AndroWish-style: event + data dict) ----------------------
proc cb {event data} {
    switch -- $event {

        scan {
            set name [dict get $data name]
            if {!$::found && [string match -nocase "Skale*" $name]} {
                set ::found 1
                set addr [dict get $data address]
                show "found Skale"
                ble stop $::scanner
                set ::skale [ble connect $addr cb 0]
                puts "connecting to $addr -> handle $::skale"
            }
        }

        characteristic {
            switch -- [dict get $data state] {
                discovery {
                    # Remember the instance ids exactly like bluetooth.tcl does,
                    # so enable/write can address the characteristic later.
                    set ::sinstance([dict get $data suuid]) [dict get $data sinstance]
                    set ::cinstance([dict get $data cuuid]) [dict get $data cinstance]
                }
                connected {
                    if {[dict get $data cuuid] eq $::WEIGHT} {
                        # weight notification: skip the flag byte, read a signed
                        # little-endian int16, divide by 10 -> grams
                        binary scan [dict get $data value] xs raw
                        if {[info exists raw]} {
                            show [format "%.1f g" [expr {$raw / 10.0}]]
                        }
                    }
                }
            }
        }

        connection {
            if {[dict get $data state] eq "connected"} {
                puts "connected"
                after 400 enable
            } elseif {[dict get $data state] eq "disconnected"} {
                show "disconnected"
            }
        }
    }
}

proc enable {} {
    # turn on weight notifications + the LCD weight display
    ble enable $::skale $::SUUID $::sinstance($::SUUID) $::WEIGHT $::cinstance($::WEIGHT)
    ble write  $::skale $::SUUID $::sinstance($::SUUID) $::CMD   $::cinstance($::CMD) $::CMD_DISPLAY_WEIGHT
    # demonstrate a write: tare 3 s after connecting
    after 3000 tare
}

proc tare {} {
    puts ">>> tare"
    ble write $::skale $::SUUID $::sinstance($::SUUID) $::CMD $::cinstance($::CMD) $::CMD_TARE
}

# --- go ---------------------------------------------------------------------
puts "Bluetooth state: [ble state]"
set ::scanner [ble scanner cb]
puts "scanning for a Skale... (Ctrl-C / close window to quit)"

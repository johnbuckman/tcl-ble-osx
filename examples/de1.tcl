# de1.tcl -- Decent Espresso DE1 state monitor (read-only).
#
# Scans for a DE1, connects, enables StateInfo notifications, and prints the
# machine state as it changes.  Sends no commands to the machine.
#
# Run:  /usr/local/bin/wish8.6 examples/de1.tcl
#
# SPDX-License-Identifier: TCL

set here [file dirname [file normalize [info script]]]
lappend auto_path [file join $here ..]
package require ble

set SUUID     0000A000-0000-1000-8000-00805F9B34FB   ;# DE1 service
set STATEINFO 0000A00E-0000-1000-8000-00805F9B34FB   ;# notify/read: machine state

array set ::statename {0 Sleep 1 GoingToSleep 2 Idle 3 Busy 4 Espresso 5 Steam 6 HotWater 7 ShortCal 8 SelfTest 9 LongCal}
set ::de1   0
set ::found 0
array set ::sinstance {}
array set ::cinstance {}

catch { wm withdraw . }

proc cb {event data} {
    switch -- $event {
        scan {
            if {!$::found && [string match -nocase "DE1*" [dict get $data name]]} {
                set ::found 1
                set addr [dict get $data address]
                puts "found DE1 $addr -- connecting"
                ble stop $::scanner
                set ::de1 [ble connect $addr cb 0]
            }
        }
        characteristic {
            switch -- [dict get $data state] {
                discovery {
                    set ::sinstance([dict get $data suuid]) [dict get $data sinstance]
                    set ::cinstance([dict get $data cuuid]) [dict get $data cinstance]
                }
                connected {
                    if {[dict get $data cuuid] eq $::STATEINFO} {
                        binary scan [dict get $data value] cu s
                        set n [expr {[info exists ::statename($s)] ? $::statename($s) : "?"}]
                        puts "DE1 state: $s ($n)"
                    }
                }
            }
        }
        connection {
            if {[dict get $data state] eq "connected"} {
                puts "connected (mtu [dict get $data mtu])"
                after 400 {
                    ble enable $::de1 $::SUUID $::sinstance($::SUUID) $::STATEINFO $::cinstance($::STATEINFO)
                    ble read   $::de1 $::SUUID $::sinstance($::SUUID) $::STATEINFO $::cinstance($::STATEINFO)
                }
            }
        }
    }
}

puts "Bluetooth state: [ble state]"
set ::scanner [ble scanner cb]
puts "scanning for a DE1..."

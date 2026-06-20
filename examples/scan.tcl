# scan.tcl -- list nearby Bluetooth LE devices.
#
# Run:  /usr/local/bin/wish8.6 examples/scan.tcl
#
# SPDX-License-Identifier: TCL

set here [file dirname [file normalize [info script]]]
lappend auto_path [file join $here ..]
package require ble

catch { wm withdraw . }
array set ::seen {}

proc cb {event data} {
    if {$event ne "scan"} return
    set addr [dict get $data address]
    if {[info exists ::seen($addr)]} return
    set ::seen($addr) 1
    set name [string trim [dict get $data name]]
    set rssi [dict get $data rssi]
    puts [format "%4d dBm  %-28s  %s" $rssi [expr {$name eq "" ? "(no name)" : $name}] $addr]
}

puts "Bluetooth state: [ble state]"
puts "scanning for 15s..."
set s [ble scanner cb]
after 15000 { ble stop $s; puts "done."; after 300 exit }

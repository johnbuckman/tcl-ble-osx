# Tcl package index for the macOS "ble" command.
# Place this directory on auto_path (or its parent, which Tcl scans one level
# deep) and `package require ble` will load it.
package ifneeded ble 1.0 [list source [file join $dir ble.tcl]]

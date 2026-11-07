# Out-of-context synthesis, placement and routing of one RTL block (batch Tcl, no GUI steps).
#
#   scripts/vivado.sh -mode batch -source syn/synth_ooc.tcl -tclargs <top> [clk_mhz] [part]
#   make synth          (rs_decoder at CCSDS and KP4)
#   make synth-ooc TOP=rs_decoder GENERICS="M=10 ..." NAME=rs_decoder_kp4
#
# Optional environment: OOC_GENERICS (space-separated NAME=VALUE parameter overrides) and OOC_NAME (the report
# directory and result name, so a variant does not overwrite the default build's reports; default <top>).
#
# Out of context: the block's ports are internal streams, not pins, so no I/O buffers or pin constraints.
# It runs to route_design because post-synthesis timing is an estimate of routing delay; post-route is measured.
# Reports go to docs/reports/ooc/<name>/ (summary.txt holds WNS).

set pinned_version 2025.2  ;# the CCSDS receiver's pinned toolchain
if {[version -short] ne $pinned_version} {
    puts "WARNING: Vivado [version -short] is not the pinned $pinned_version"
}

set top     [lindex $argv 0]
set clk_mhz [expr {[llength $argv] > 1 ? [lindex $argv 1] : 100}]
set part    [expr {[llength $argv] > 2 ? [lindex $argv 2] : "xc7a100tcsg324-1"}]
if {$top eq ""} { error "usage: -tclargs <top> \[clk_mhz\] \[part\]" }

set name     [expr {[info exists ::env(OOC_NAME)] && $::env(OOC_NAME) ne "" ? $::env(OOC_NAME) : $top}]
set generics {}
if {[info exists ::env(OOC_GENERICS)]} {
    foreach g $::env(OOC_GENERICS) { lappend generics -generic $g }
}

set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root docs reports ooc $name]
file mkdir $out

# The package first, then every module; synth_design keeps only what $top instantiates.
read_verilog -sv [file join $root rtl rs_gf_pkg.sv]
read_verilog -sv [lsearch -all -inline -not -glob [lsort [glob [file join $root rtl *.sv]]] *rs_gf_pkg.sv]

synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt {*}$generics
create_clock -name clk -period [expr {1000.0 / $clk_mhz}] [get_ports clk_i]
report_utilization -file [file join $out synth_utilization.rpt]

opt_design
place_design
route_design

report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out utilization_hier.rpt]
report_drc -file [file join $out drc.rpt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set f [open [file join $out summary.txt] w]
puts $f "top $top"
if {[llength $generics]} { puts $f "generics $::env(OOC_GENERICS)" }
puts $f "part $part"
puts $f "vivado [version -short]"
puts $f "clk_mhz $clk_mhz"
puts $f "wns_ns $wns"
close $f
puts "OOC $name @ $clk_mhz MHz: WNS $wns ns"

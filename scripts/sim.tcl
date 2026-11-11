#*****************************************************************************
# sim.tcl - behavioral sim of the production_test RTL (xsim, unisim).
#
#   vivado -mode batch -source scripts/sim.tcl
#
# Runs tb_prodtest_i2c_slave (combined DNA 0x33 + SYSMON 0x32 I2C slave) to
# completion; it calls std.env.stop and prints PASS/FAIL notes.  The DRP reader
# has its own bench, tb_sysmon_drp_reader (set TB below to switch).
#
# NOTE: if 'launch_simulation' fails to spawn xvhdl in your shell, run the xsim
# tools directly with Vivado/bin on PATH, e.g.:
#   xvhdl --2008 -work work rtl/prodtest_i2c_slave.vhd rtl/sysmon_drp_reader.vhd \
#         sim/tb_prodtest_i2c_slave.vhd sim/tb_sysmon_drp_reader.vhd
#   xelab -L unisim work.tb_prodtest_i2c_slave -s snap && xsim snap -R
#*****************************************************************************
set part   "xcau7p-fcva289-2-i"
set origin [file normalize [file dirname [info script]]/..]
set simdir [file join $origin vivado_sim]
set TB     tb_prodtest_i2c_slave   ;# or tb_sysmon_drp_reader

create_project -force prodtest_sim $simdir -part $part
set_property target_language VHDL [current_project]

set rtl [list \
  [file join $origin rtl prodtest_i2c_slave.vhd] \
  [file join $origin rtl sysmon_drp_reader.vhd] ]
set tb  [list \
  [file join $origin sim tb_prodtest_i2c_slave.vhd] \
  [file join $origin sim tb_sysmon_drp_reader.vhd] ]

add_files -norecurse $rtl
add_files -fileset sim_1 -norecurse $tb
foreach f [concat $rtl $tb] { set_property file_type {VHDL 2008} [get_files $f] }

set_property top $TB [get_filesets sim_1]
update_compile_order -fileset sim_1

set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
launch_simulation
run all

puts "======================================================================"
puts " production_test behavioral simulation complete (see PASS/FAIL above)."
puts "======================================================================"

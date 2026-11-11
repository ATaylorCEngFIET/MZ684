#*****************************************************************************
# build.tcl - production_test FPGA image, AUP Explorer (XCAU7P-FCVA289)
#
# ONE I2C slave on the RP2040 (U11) link pins N4(SDA)/R7(SCL), answering three
# addresses:
#   0x33 : 96-bit FPGA Device DNA (DNA_PORTE2)
#   0x32 : SYSMON raw channels (temp, VCCINT, VCCAUX, VBRAM), read over DRP
#   0x34 : SEM config-memory status (read); write = inject / clear counters
# SYSMON is read through its DRP port (no pad of its own) by sysmon_drp_reader.
# SEM (Soft Error Mitigation) is reached over AXI4-Lite: sem_axi_status (slave,
# wraps the SEM core + ICAPE3/FRAME_ECCE4) <- axil_master_bridge (master) <- I2C.
# RTL + two IPs (System Management Wizard DRP, sem_ultra); no block design.
#
# Vivado 2026.1.  Run from the hw/ folder:
#   vivado -mode batch -source scripts/build.tcl
#*****************************************************************************
set part    "xcau7p-fcva289-2-i"
set proj    "production_test"
set origin  [file normalize [file dirname [info script]]/..]
set RUN_IMPL 1   ;# 1 = synth + impl + bitstream ; 0 = stop after synth

create_project -force $proj [file join $origin vivado] -part $part
set_property target_language VHDL [current_project]

# ---- System Management Wizard in DRP mode (module_name sysmon_drp) ----------
create_ip -name system_management_wiz -vendor xilinx.com -library ip \
          -module_name sysmon_drp
set_property -dict [list \
  CONFIG.INTERFACE_SELECTION {DRP} \
  CONFIG.CHANNEL_ENABLE_VP_VN {false} \
  CONFIG.CHANNEL_ENABLE_TEMPERATURE {true} \
  CONFIG.CHANNEL_ENABLE_VCCINT {true} \
  CONFIG.CHANNEL_ENABLE_VCCAUX {true} \
  CONFIG.CHANNEL_ENABLE_VBRAM {true} \
  CONFIG.SEQUENCER_MODE {Continuous} \
] [get_ips sysmon_drp]
generate_target {synthesis instantiation_template} [get_ips sysmon_drp]

# ---- UltraScale+ Soft Error Mitigation (sem_ultra, module_name sem_core) -----
# Mitigation + testing (injection enabled); config primitives are supplied by us
# (sem_core_cfg.v) per the default LOCATE_CONFIG_PRIM=example_design.  Clock the
# controller at the design's 100 MHz (10000 ps) - within the AU7P ICAP FMax.
create_ip -name sem_ultra -vendor xilinx.com -library ip -module_name sem_core
set_property -dict [list \
  CONFIG.MODE {mitigation_and_testing} \
  CONFIG.CLOCK_PERIOD {10000} \
] [get_ips sem_core]
generate_target {synthesis instantiation_template} [get_ips sem_core]

# ---- RTL --------------------------------------------------------------------
add_files -norecurse [list \
  [file join $origin rtl prodtest_i2c_slave.vhd] \
  [file join $origin rtl sysmon_drp_reader.vhd] \
  [file join $origin rtl sem_core_cfg.v] \
  [file join $origin rtl sem_axi_status.vhd] \
  [file join $origin rtl axil_master_bridge.vhd] \
  [file join $origin rtl production_test_top.vhd] ]
set_property top production_test_top [current_fileset]

add_files -fileset constrs_1 -norecurse [file join $origin xdc production_test.xdc]
update_compile_order -fileset sources_1

# ---- Synthesis --------------------------------------------------------------
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  error "Synthesis failed - see synth_1 log."
}

if {!$RUN_IMPL} {
  puts "=== Synthesis complete; RUN_IMPL=0, stopping before implementation. ==="
  return
}

# ---- Implementation + bitstream ---------------------------------------------
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  error "Implementation/bitstream failed - see impl_1 log."
}

open_run impl_1
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
puts "======================================================================"
puts " production_test bitstream written."
puts "   WNS = $wns ns   TNS = $tns ns"
puts "   bit: vivado/${proj}.runs/impl_1/production_test_top.bit"
puts "======================================================================"

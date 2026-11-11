# MZ684 — FPGA production-test RTL (DNA + SYSMON + SEM over one I²C link)

RTL for a board-identity / health image on an **AMD Artix UltraScale+ XCAU7P
(FCVA289)**. A single I²C slave on two package pins answers **three** addresses,
so a host MCU (here an on-board RP2040) can read the FPGA's identity and the
health of its silicon and configuration memory over one 2-wire link:

| I²C addr | Payload | Source |
|----------|---------|--------|
| `0x33` | 96-bit **Device DNA** (12 bytes, MSB first) | `DNA_PORTE2` primitive |
| `0x32` | **SYSMON** raw channels — die temp, VCCINT, VCCAUX, VCCBRAM (8 bytes) | System Management Wizard in **DRP** mode, polled by `sysmon_drp_reader` |
| `0x34` | **SEM** config-memory status (8 bytes); an I²C *write* triggers inject (bit0) / clear (bit1) | UltraScale+ **Soft Error Mitigation** core, reached over **AXI4-Lite** |

The SEM (Soft Error Mitigation) core continuously scans the FPGA configuration
memory for single-event upsets, corrects single-bit (ECC) errors and flags
multi-bit / CRC (uncorrectable) errors. Writing the inject command flips one
configuration-memory bit so the scrubber detects and corrects it — the corrected
count then increments, proving the monitor is live.

## Architecture

```
          inject/clear          AXI4-Lite
 I²C slave ───────────► AXI master ───────────► sem_axi_status (AXI4-Lite slave)
 (0x32/0x33/0x34)  ◄─── (axil_master_bridge) ◄───   ├─ SEM core (status + command iface)
      │  sem_data cache                              └─ ICAPE3 + FRAME_ECCE4
      │
   one IOBUF (SDA, open-drain) + SCL input-only   ← the only tristate, at the top
```

* `0x32`/`0x33` keep the SYSMON-DRP and DNA paths unchanged.
* `0x34` is served from a cache that `axil_master_bridge` (an AXI4-Lite **master**)
  continuously reads from `sem_axi_status` (the AXI4-Lite **slave** wrapping the
  SEM core) — so I²C reads never clock-stretch. Inject/clear become AXI writes.
* The SEM parallel **command interface** issues *Enter Idle → Error Injection →
  Enter Observation* (PG187, Table 3-2, UltraScale+ `command_code[43:0]`
  encoding); the whole injection payload `{slr, LFA, word, bit}` maps onto
  `command_code[31:0]`.

## Source files

| File | Role |
|------|------|
| `rtl/production_test_top.vhd` | top level; one SDA IOBUF, wires SYSMON + SEM-over-AXI + I²C slave |
| `rtl/prodtest_i2c_slave.vhd` | 3-address I²C slave (reads DNA/SYSMON/SEM; writes trigger inject/clear) |
| `rtl/sysmon_drp_reader.vhd` | tiny DRP master that polls the SYSMON status registers |
| `rtl/sem_axi_status.vhd` | AXI4-Lite slave: wraps the SEM core + config primitives, status counters, inject sequencer |
| `rtl/axil_master_bridge.vhd` | AXI4-Lite master: caches SEM registers for I²C, issues inject/clear writes |
| `xdc/production_test.xdc` | pin + clock constraints (SDA `N4`, SCL `R7`, 100 MHz clk `P8`) |
| `scripts/build.tcl` | Vivado 2026.1 batch build (creates the IPs, synth → impl → bitstream) |
| `scripts/sim.tcl` | simulation setup notes |
| `sim/tb_*.vhd` | self-checking testbenches |

## Building (Vivado 2026.1)

```tcl
cd <repo>
vivado -mode batch -source scripts/build.tcl
```

`build.tcl` creates both IPs via `create_ip` (no block design):
`system_management_wiz` (DRP mode) and `sem_ultra` (mitigation + testing,
`CLOCK_PERIOD=10000` → 100 MHz, within the AU7P ICAP FMax).

### One generated file is **not** in this repo: `sem_core_cfg.v`

The SEM core is delivered with `LOCATE_CONFIG_PRIM=example_design`, so the
`ICAPE3` + `FRAME_ECCE4` configuration primitives live in an AMD-provided wrapper
`sem_core_cfg.v`. That file is AMD IP example code (marked proprietary) and is
**not redistributed here**. Generate it from your own Vivado install:

```tcl
create_project sem_tmp ./sem_tmp -part xcau7p-fcva289-2-i
create_ip -name sem_ultra -vendor xilinx.com -library ip -module_name sem_core
set_property -dict {CONFIG.MODE mitigation_and_testing CONFIG.CLOCK_PERIOD 10000} [get_ips sem_core]
open_example_project -force -dir ./sem_ex [get_ips sem_core]
# copy sem_ex/sem_core_ex/imports/sem_core_cfg.v  ->  rtl/sem_core_cfg.v
```

Then `build.tcl` (which already lists `rtl/sem_core_cfg.v`) will build end-to-end.

## Target / tooling

* Device: `xcau7p-fcva289-2-i` (Artix UltraScale+)
* Vivado 2026.1
* Single 100 MHz clock domain; timing closes with WNS ≈ +5.7 ns.

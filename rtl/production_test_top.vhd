--------------------------------------------------------------------------------
-- production_test_top.vhd  -  AUP Explorer production_test (XCAU7P-FCVA289)
--
-- Board-identity / health image.  One read-only-ish I2C slave on the RP2040
-- (U11) link pins N4(SDA)/R7(SCL) = GPIO8/9 serves THREE addresses:
--   0x33 : 96-bit FPGA Device DNA
--   0x32 : SYSMON raw channels (die temp, VCCINT, VCCAUX, VBRAM)
--   0x34 : SEM config-memory status (8 bytes); an I2C WRITE to 0x34 triggers an
--          error-injection (bit0) or a counter clear (bit1).
--
-- SYSMON is read through its DRP port (sysmon_drp_reader).  SEM (Soft Error
-- Mitigation) is reached over an AXI4-Lite bus: sem_axi_status is the slave that
-- wraps the SEM core + ICAPE3/FRAME_ECCE4, and axil_master_bridge is the master
-- that polls it into a cache for the I2C slave and issues inject/clear writes.
--
--   I2C slave --inject/clear--> AXI master --AXI4-Lite--> sem_axi_status --> SEM
--             <----sem_data----           <--------------
--
-- Tristate exists ONLY here: one IOBUF for SDA; SCL is input-only.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity production_test_top is
  port (
    clk_100m : in    std_logic;    -- 100 MHz, ball P8 (bank 84)
    i2c_scl  : in    std_logic;    -- I2C clock, ball R7 (U11 GPIO9) - input only
    i2c_sda  : inout std_logic     -- I2C data,  ball N4 (U11 GPIO8) - open-drain
  );
end entity production_test_top;

architecture str of production_test_top is

  -- System Management Wizard in DRP mode (module_name sysmon_drp, build.tcl).
  component sysmon_drp is
    port (
      di_in               : in  std_logic_vector(15 downto 0);
      daddr_in            : in  std_logic_vector(7 downto 0);
      den_in              : in  std_logic;
      dwe_in              : in  std_logic;
      drdy_out            : out std_logic;
      do_out              : out std_logic_vector(15 downto 0);
      dclk_in             : in  std_logic;
      reset_in            : in  std_logic;
      user_temp_alarm_out : out std_logic;
      vccint_alarm_out    : out std_logic;
      vccaux_alarm_out    : out std_logic;
      ot_out              : out std_logic;
      channel_out         : out std_logic_vector(5 downto 0);
      eoc_out             : out std_logic;
      alarm_out           : out std_logic;
      eos_out             : out std_logic;
      busy_out            : out std_logic
    );
  end component sysmon_drp;

  signal sda_i, sda_oe : std_logic;

  -- DRP net bundle (SYSMON)
  signal den, dwe, drdy : std_logic;
  signal daddr          : std_logic_vector(7 downto 0);
  signal di, do         : std_logic_vector(15 downto 0);
  signal s_temp, s_vccint, s_vccaux, s_vbram : std_logic_vector(15 downto 0);
  signal sysmon_data : std_logic_vector(63 downto 0);

  -- SEM path
  signal sem_data   : std_logic_vector(63 downto 0);
  signal inject_req, clear_req : std_logic;

  -- AXI4-Lite bus (master bridge <-> sem_axi_status)
  signal ax_awaddr  : std_logic_vector(7 downto 0);
  signal ax_awvalid, ax_awready : std_logic;
  signal ax_wdata   : std_logic_vector(31 downto 0);
  signal ax_wstrb   : std_logic_vector(3 downto 0);
  signal ax_wvalid, ax_wready   : std_logic;
  signal ax_bresp   : std_logic_vector(1 downto 0);
  signal ax_bvalid, ax_bready   : std_logic;
  signal ax_araddr  : std_logic_vector(7 downto 0);
  signal ax_arvalid, ax_arready : std_logic;
  signal ax_rdata   : std_logic_vector(31 downto 0);
  signal ax_rresp   : std_logic_vector(1 downto 0);
  signal ax_rvalid, ax_rready   : std_logic;

  -- Power-on reset: hold for the first ~256 clocks after configuration.
  signal rst_cnt    : unsigned(8 downto 0) := (others => '0');
  signal sysmon_rst : std_logic := '1';     -- active-high SYSMON reset
  signal aresetn    : std_logic := '0';     -- active-low AXI/SEM-logic reset

begin

  reset_proc : process(clk_100m)
  begin
    if rising_edge(clk_100m) then
      if rst_cnt(8) = '0' then
        rst_cnt <= rst_cnt + 1;
      end if;
      sysmon_rst <= not rst_cnt(8);
      aresetn    <= rst_cnt(8);
    end if;
  end process;

  -- Single SDA IOBUF (the only tristate in the design).
  u_sda_iobuf : IOBUF
    port map (IO => i2c_sda, I => '0', T => not sda_oe, O => sda_i);

  ----------------------------------------------------------------------------
  -- SYSMON via DRP (unchanged)
  ----------------------------------------------------------------------------
  u_sysmon : sysmon_drp
    port map (
      di_in    => di,
      daddr_in => daddr,
      den_in   => den,
      dwe_in   => dwe,
      drdy_out => drdy,
      do_out   => do,
      dclk_in  => clk_100m,
      reset_in => sysmon_rst,
      user_temp_alarm_out => open,
      vccint_alarm_out    => open,
      vccaux_alarm_out    => open,
      ot_out              => open,
      channel_out         => open,
      eoc_out             => open,
      alarm_out           => open,
      eos_out             => open,
      busy_out            => open
    );

  u_reader : entity work.sysmon_drp_reader
    port map (
      clk => clk_100m,
      den => den, dwe => dwe, daddr => daddr, di => di, do => do, drdy => drdy,
      temp => s_temp, vccint => s_vccint, vccaux => s_vccaux, vbram => s_vbram
    );

  sysmon_data <= s_temp & s_vccint & s_vccaux & s_vbram;

  ----------------------------------------------------------------------------
  -- SEM over AXI4-Lite
  ----------------------------------------------------------------------------
  u_sem : entity work.sem_axi_status
    port map (
      clk           => clk_100m,
      aresetn       => aresetn,
      s_axi_awaddr  => ax_awaddr,
      s_axi_awvalid => ax_awvalid,
      s_axi_awready => ax_awready,
      s_axi_wdata   => ax_wdata,
      s_axi_wstrb   => ax_wstrb,
      s_axi_wvalid  => ax_wvalid,
      s_axi_wready  => ax_wready,
      s_axi_bresp   => ax_bresp,
      s_axi_bvalid  => ax_bvalid,
      s_axi_bready  => ax_bready,
      s_axi_araddr  => ax_araddr,
      s_axi_arvalid => ax_arvalid,
      s_axi_arready => ax_arready,
      s_axi_rdata   => ax_rdata,
      s_axi_rresp   => ax_rresp,
      s_axi_rvalid  => ax_rvalid,
      s_axi_rready  => ax_rready
    );

  u_bridge : entity work.axil_master_bridge
    port map (
      clk        => clk_100m,
      aresetn    => aresetn,
      inject_req => inject_req,
      clear_req  => clear_req,
      sem_data   => sem_data,
      m_axi_awaddr  => ax_awaddr,
      m_axi_awvalid => ax_awvalid,
      m_axi_awready => ax_awready,
      m_axi_wdata   => ax_wdata,
      m_axi_wstrb   => ax_wstrb,
      m_axi_wvalid  => ax_wvalid,
      m_axi_wready  => ax_wready,
      m_axi_bresp   => ax_bresp,
      m_axi_bvalid  => ax_bvalid,
      m_axi_bready  => ax_bready,
      m_axi_araddr  => ax_araddr,
      m_axi_arvalid => ax_arvalid,
      m_axi_arready => ax_arready,
      m_axi_rdata   => ax_rdata,
      m_axi_rresp   => ax_rresp,
      m_axi_rvalid  => ax_rvalid,
      m_axi_rready  => ax_rready
    );

  ----------------------------------------------------------------------------
  -- One I2C slave for all three payloads (0x32/0x33/0x34) + inject/clear writes
  ----------------------------------------------------------------------------
  u_slave : entity work.prodtest_i2c_slave
    generic map (
      DNA_ADDR    => "0110011",       -- 0x33
      SYSMON_ADDR => "0110010",       -- 0x32
      SEM_ADDR    => "0110100"        -- 0x34
    )
    port map (
      clk         => clk_100m,
      scl_i       => i2c_scl,
      sda_i       => sda_i,
      sda_oe      => sda_oe,
      sysmon_data => sysmon_data,
      sem_data    => sem_data,
      inject_req  => inject_req,
      clear_req   => clear_req
    );

end architecture str;

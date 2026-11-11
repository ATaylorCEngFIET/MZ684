--------------------------------------------------------------------------------
-- sem_axi_status.vhd  -  AUP Explorer production_test
--
-- AXI4-Lite peripheral that wraps the UltraScale+ Soft Error Mitigation core
-- (sem_ultra, module "sem_core") plus its ICAPE3/FRAME_ECCE4 config primitives
-- (sem_core_cfg), and exposes the configuration-memory health as registers:
--
--   0x00 STATUS      (RO)  live + sticky controller status, derived state
--   0x04 CORR_COUNT  (RO)  number of correctable SEU events corrected
--   0x08 HB_COUNT    (RO)  heartbeat pulses (scrubber-alive / scan progress)
--   0x0C UNCORR_COUNT(RO)  number of uncorrectable (CRC) events
--   0x10 INJECT_ADDR (RW)  command_code[31:0] injection payload {ss,LFA,word,bit}
--   0x14 CONTROL     (WO)  bit0=inject (flip a config bit), bit1=clear counters
--   0x18 CTRL_STATUS (RO)  bit0=inject_busy, bit1=command_busy, [7:4]=state
--
-- Injection drives the SEM parallel command interface (PG187, Table 3-2,
-- UltraScale+ encoding): Enter Idle (0xE..) -> Error Injection (0xC00<<32 | addr)
-- -> Enter Observation (0xA..), each gated on command_busy and the status pins.
-- A single-bit flip is always correctable, so the scrubber detects it, pulses
-- status_correction, and CORR_COUNT increments - proving the monitor works.
--
-- The SEM owns the device's single ICAPE3 + FRAME_ECCE4 (no other ICAP user).
-- Clocked entirely by clk (= icap_clk); 100 MHz is within the AU7P ICAP FMax.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sem_axi_status is
  port (
    -- Clock / reset (AXI4-Lite + SEM share this domain)
    clk           : in  std_logic;                      -- 100 MHz, = icap_clk
    aresetn       : in  std_logic;                      -- active-low reset

    -- AXI4-Lite slave
    s_axi_awaddr  : in  std_logic_vector(7 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(7 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic
  );
end entity sem_axi_status;

architecture rtl of sem_axi_status is

  ------------------------------------------------------------------------------
  -- SEM IP core (module_name sem_core, created by build.tcl).  Port list copied
  -- from the generated sem_core.vho instantiation template (sem_ultra v3.1).
  ------------------------------------------------------------------------------
  component sem_core is
    port (
      status_heartbeat       : out std_logic;
      status_initialization  : out std_logic;
      status_observation     : out std_logic;
      status_correction      : out std_logic;
      status_classification  : out std_logic;
      status_injection       : out std_logic;
      status_essential       : out std_logic;
      status_uncorrectable   : out std_logic;
      status_diagnostic_scan : out std_logic;
      status_detect_only     : out std_logic;
      monitor_txdata         : out std_logic_vector(7 downto 0);
      monitor_txwrite        : out std_logic;
      monitor_txfull         : in  std_logic;
      monitor_rxdata         : in  std_logic_vector(7 downto 0);
      monitor_rxread         : out std_logic;
      monitor_rxempty        : in  std_logic;
      command_strobe         : in  std_logic;
      command_busy           : out std_logic;
      command_code           : in  std_logic_vector(43 downto 0);
      icap_clk               : in  std_logic;
      icap_o                 : in  std_logic_vector(31 downto 0);
      icap_csib              : out std_logic;
      icap_rdwrb             : out std_logic;
      icap_i                 : out std_logic_vector(31 downto 0);
      icap_prerror           : in  std_logic;
      icap_prdone            : in  std_logic;
      icap_avail             : in  std_logic;
      cap_rel                : in  std_logic;
      cap_gnt                : in  std_logic;
      cap_req                : out std_logic;
      fecc_eccerrornotsingle : in  std_logic;
      fecc_eccerrorsingle    : in  std_logic;
      fecc_endofframe        : in  std_logic;
      fecc_endofscan         : in  std_logic;
      fecc_crcerror          : in  std_logic;
      fecc_far               : in  std_logic_vector(26 downto 0);
      fecc_farsel            : out std_logic_vector(1 downto 0);
      aux_error_cr_ne        : in  std_logic;
      aux_error_cr_es        : in  std_logic;
      aux_error_uc           : in  std_logic
    );
  end component sem_core;

  -- ICAPE3 + FRAME_ECCE4 wrapper (AMD example file sem_core_cfg.v, Verilog).
  component sem_core_cfg is
    port (
      icap_clk               : in  std_logic;
      icap_o                 : out std_logic_vector(31 downto 0);
      icap_csib              : in  std_logic;
      icap_rdwrb             : in  std_logic;
      icap_i                 : in  std_logic_vector(31 downto 0);
      icap_prerror           : out std_logic;
      icap_prdone            : out std_logic;
      icap_avail             : out std_logic;
      fecc_eccerrornotsingle : out std_logic;
      fecc_eccerrorsingle    : out std_logic;
      fecc_endofframe        : out std_logic;
      fecc_endofscan         : out std_logic;
      fecc_crcerror          : out std_logic;
      fecc_far               : out std_logic_vector(26 downto 0);
      fecc_farsel            : in  std_logic_vector(1 downto 0)
    );
  end component sem_core_cfg;

  ------------------------------------------------------------------------------
  -- SEM <-> cfg nets
  ------------------------------------------------------------------------------
  signal n_icap_o   : std_logic_vector(31 downto 0);
  signal n_icap_i   : std_logic_vector(31 downto 0);
  signal n_icap_csib, n_icap_rdwrb              : std_logic;
  signal n_icap_prerror, n_icap_prdone, n_icap_avail : std_logic;
  signal n_fecc_ens, n_fecc_es, n_fecc_eof, n_fecc_eos, n_fecc_crc : std_logic;
  signal n_fecc_far    : std_logic_vector(26 downto 0);
  signal n_fecc_farsel : std_logic_vector(1 downto 0);

  -- Controller status
  signal st_hb, st_init, st_obs, st_corr, st_class, st_inj, st_ess, st_uncorr,
         st_diag, st_detect : std_logic;
  signal st_corr_d, st_uncorr_d, st_hb_d : std_logic := '0';

  -- Command interface
  signal cmd_strobe : std_logic := '0';
  signal cmd_busy   : std_logic;
  signal cmd_code   : std_logic_vector(43 downto 0) := (others => '0');

  -- ICAP arbitration (single user: grant one cycle after request)
  signal cap_req, cap_gnt : std_logic := '0';

  ------------------------------------------------------------------------------
  -- Captured health registers
  ------------------------------------------------------------------------------
  signal corr_count   : unsigned(31 downto 0) := (others => '0');
  signal uncorr_count : unsigned(31 downto 0) := (others => '0');
  signal hb_count     : unsigned(31 downto 0) := (others => '0');
  signal corr_sticky, uncorr_sticky, ess_sticky, hb_to_sticky : std_logic := '0';

  -- Heartbeat watchdog: ~2.7 s window at 100 MHz (2^28 cycles).
  signal hb_wd    : unsigned(27 downto 0) := (others => '0');
  signal hb_alive : std_logic := '0';

  -- Injection payload + control pulses (set by AXI writes)
  signal inject_addr   : std_logic_vector(31 downto 0) := (others => '0');
  signal ctrl_inject_p : std_logic := '0';
  signal ctrl_clear_p  : std_logic := '0';
  signal inject_pending: std_logic := '0';

  -- Injection sequencer
  type ij_t is (IJ_IDLE, IJ_IDLE_CMD, IJ_IDLE_STB, IJ_WAIT_IDLE,
                IJ_INJ_CMD, IJ_INJ_STB, IJ_WAIT_INJ,
                IJ_OBS_CMD, IJ_OBS_STB, IJ_WAIT_OBS, IJ_ABORT);
  signal ijst       : ij_t := IJ_IDLE;
  signal inject_busy: std_logic := '0';
  signal ij_tmo     : unsigned(23 downto 0) := (others => '0');
  constant IJ_TMO_MAX : unsigned(23 downto 0) := to_unsigned(10_000_000, 24); -- ~0.1 s

  -- UltraScale+ command_code encodings (PG187 Table 3-2)
  constant CMD_IDLE : std_logic_vector(43 downto 0) := b"1110" & x"0000000000";
  constant CMD_OBS  : std_logic_vector(43 downto 0) := b"1010" & x"0000000000";

  -- Derived 4-bit state code (see CTRL_STATUS / firmware)
  signal state_code : std_logic_vector(3 downto 0);

  ------------------------------------------------------------------------------
  -- AXI4-Lite slave (canonical single-register-bank implementation)
  ------------------------------------------------------------------------------
  signal axi_awready : std_logic := '0';
  signal axi_wready  : std_logic := '0';
  signal axi_bvalid  : std_logic := '0';
  signal axi_arready : std_logic := '0';
  signal axi_araddr  : std_logic_vector(7 downto 0) := (others => '0');
  signal axi_rvalid  : std_logic := '0';
  signal axi_rdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_en, rd_en : std_logic;

begin

  ------------------------------------------------------------------------------
  -- SEM core + config primitives
  ------------------------------------------------------------------------------
  u_sem : sem_core
    port map (
      status_heartbeat       => st_hb,
      status_initialization  => st_init,
      status_observation     => st_obs,
      status_correction      => st_corr,
      status_classification  => st_class,
      status_injection       => st_inj,
      status_essential       => st_ess,
      status_uncorrectable   => st_uncorr,
      status_diagnostic_scan => st_diag,
      status_detect_only     => st_detect,
      monitor_txdata         => open,
      monitor_txwrite        => open,
      monitor_txfull         => '0',
      monitor_rxdata         => x"00",
      monitor_rxread         => open,
      monitor_rxempty        => '1',
      command_strobe         => cmd_strobe,
      command_busy           => cmd_busy,
      command_code           => cmd_code,
      icap_clk               => clk,
      icap_o                 => n_icap_o,
      icap_csib              => n_icap_csib,
      icap_rdwrb             => n_icap_rdwrb,
      icap_i                 => n_icap_i,
      icap_prerror           => n_icap_prerror,
      icap_prdone            => n_icap_prdone,
      icap_avail             => n_icap_avail,
      cap_rel                => '0',
      cap_gnt                => cap_gnt,
      cap_req                => cap_req,
      fecc_eccerrornotsingle => n_fecc_ens,
      fecc_eccerrorsingle    => n_fecc_es,
      fecc_endofframe        => n_fecc_eof,
      fecc_endofscan         => n_fecc_eos,
      fecc_crcerror          => n_fecc_crc,
      fecc_far               => n_fecc_far,
      fecc_farsel            => n_fecc_farsel,
      aux_error_cr_ne        => '0',
      aux_error_cr_es        => '0',
      aux_error_uc           => '0'
    );

  u_cfg : sem_core_cfg
    port map (
      icap_clk               => clk,
      icap_o                 => n_icap_o,
      icap_csib              => n_icap_csib,
      icap_rdwrb             => n_icap_rdwrb,
      icap_i                 => n_icap_i,
      icap_prerror           => n_icap_prerror,
      icap_prdone            => n_icap_prdone,
      icap_avail             => n_icap_avail,
      fecc_eccerrornotsingle => n_fecc_ens,
      fecc_eccerrorsingle    => n_fecc_es,
      fecc_endofframe        => n_fecc_eof,
      fecc_endofscan         => n_fecc_eos,
      fecc_crcerror          => n_fecc_crc,
      fecc_far               => n_fecc_far,
      fecc_farsel            => n_fecc_farsel
    );

  -- Single ICAP user: grant access one cycle after the controller requests it.
  arb_proc : process(clk)
  begin
    if rising_edge(clk) then
      cap_gnt <= cap_req;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Status capture, counters, heartbeat watchdog
  ------------------------------------------------------------------------------
  cap_proc : process(clk)
  begin
    if rising_edge(clk) then
      st_corr_d   <= st_corr;
      st_uncorr_d <= st_uncorr;
      st_hb_d     <= st_hb;

      -- Count correctable events on the rising edge of status_correction.
      if st_corr = '1' and st_corr_d = '0' then
        corr_count  <= corr_count + 1;
        corr_sticky <= '1';
      end if;
      -- Count uncorrectable (CRC) events on the rising edge of status_uncorrectable.
      if st_uncorr = '1' and st_uncorr_d = '0' then
        uncorr_count <= uncorr_count + 1;
        uncorr_sticky <= '1';
      end if;
      if st_ess = '1' then
        ess_sticky <= '1';
      end if;

      -- Heartbeat: count pulses, keep a watchdog that marks the scrubber alive.
      if st_hb = '1' and st_hb_d = '0' then
        hb_count <= hb_count + 1;
        hb_wd    <= (others => '0');
        hb_alive <= '1';
      elsif st_init = '1' then
        hb_wd    <= (others => '0');      -- init is not a liveness failure
      elsif hb_wd(27) = '1' then
        hb_alive    <= '0';
        hb_to_sticky <= '1';
      else
        hb_wd <= hb_wd + 1;
      end if;

      -- Clear (CONTROL bit1)
      if ctrl_clear_p = '1' then
        corr_count    <= (others => '0');
        uncorr_count  <= (others => '0');
        corr_sticky   <= '0';
        uncorr_sticky <= '0';
        ess_sticky    <= '0';
        hb_to_sticky  <= '0';
      end if;

      if aresetn = '0' then
        corr_count <= (others => '0'); uncorr_count <= (others => '0');
        hb_count   <= (others => '0'); hb_wd <= (others => '0');
        hb_alive <= '0'; corr_sticky <= '0'; uncorr_sticky <= '0';
        ess_sticky <= '0'; hb_to_sticky <= '0';
      end if;
    end if;
  end process;

  -- Derived state code: priority-encode the one-hot status pins.
  state_code <= x"0" when st_init   = '1' else   -- 0 = initialization
                x"2" when st_corr   = '1' else   -- 2 = correction
                x"3" when st_class  = '1' else   -- 3 = classification
                x"4" when st_inj    = '1' else   -- 4 = injection
                x"7" when st_diag   = '1' else   -- 7 = diagnostic scan
                x"6" when st_detect = '1' else   -- 6 = detect only
                x"1" when st_obs    = '1' else   -- 1 = observation
                x"5";                            -- 5 = idle (none asserted)

  ------------------------------------------------------------------------------
  -- Injection sequencer: idle -> inject -> observation over the command port.
  ------------------------------------------------------------------------------
  inj_proc : process(clk)
  begin
    if rising_edge(clk) then
      cmd_strobe <= '0';                   -- default: single-cycle strobe

      if ctrl_inject_p = '1' then
        inject_pending <= '1';
      end if;

      case ijst is
        when IJ_IDLE =>
          inject_busy <= '0';
          if inject_pending = '1' and st_obs = '1' and cmd_busy = '0' then
            inject_pending <= '0';
            inject_busy <= '1';
            ij_tmo <= (others => '0');
            ijst <= IJ_IDLE_CMD;
          end if;

        when IJ_IDLE_CMD =>                 -- Enter Idle
          if cmd_busy = '0' then
            cmd_code   <= CMD_IDLE;
            cmd_strobe <= '1';
            ijst <= IJ_IDLE_STB;
          end if;
        when IJ_IDLE_STB =>
          ij_tmo <= (others => '0');
          ijst <= IJ_WAIT_IDLE;
        when IJ_WAIT_IDLE =>               -- wait until the controller is fully idle
          if cmd_busy = '0' and st_obs = '0' and st_init = '0' and
             st_corr = '0' and st_class = '0' and st_diag = '0' and
             st_detect = '0' and st_inj = '0' then
            ijst <= IJ_INJ_CMD;
          elsif ij_tmo = IJ_TMO_MAX then
            ijst <= IJ_ABORT;
          else
            ij_tmo <= ij_tmo + 1;
          end if;

        when IJ_INJ_CMD =>                 -- Error Injection (LFA)
          if cmd_busy = '0' then
            cmd_code   <= b"1100" & x"00" & inject_addr;  -- 0xC00 << 32 | payload
            cmd_strobe <= '1';
            ijst <= IJ_INJ_STB;
          end if;
        when IJ_INJ_STB =>
          ij_tmo <= (others => '0');
          ijst <= IJ_WAIT_INJ;
        when IJ_WAIT_INJ =>
          if cmd_busy = '0' then
            ijst <= IJ_OBS_CMD;
          elsif ij_tmo = IJ_TMO_MAX then
            ijst <= IJ_ABORT;
          else
            ij_tmo <= ij_tmo + 1;
          end if;

        when IJ_OBS_CMD =>                 -- Enter Observation
          if cmd_busy = '0' then
            cmd_code   <= CMD_OBS;
            cmd_strobe <= '1';
            ijst <= IJ_OBS_STB;
          end if;
        when IJ_OBS_STB =>
          ij_tmo <= (others => '0');
          ijst <= IJ_WAIT_OBS;
        when IJ_WAIT_OBS =>
          if cmd_busy = '0' and st_obs = '1' then
            inject_busy <= '0';
            ijst <= IJ_IDLE;
          elsif ij_tmo = IJ_TMO_MAX then
            ijst <= IJ_ABORT;
          else
            ij_tmo <= ij_tmo + 1;
          end if;

        when IJ_ABORT =>                   -- best effort: command back to observation
          inject_busy <= '0';
          if cmd_busy = '0' then
            cmd_code   <= CMD_OBS;
            cmd_strobe <= '1';
            ijst <= IJ_IDLE;
          end if;
      end case;

      if aresetn = '0' then
        ijst <= IJ_IDLE; inject_busy <= '0'; inject_pending <= '0';
        cmd_strobe <= '0'; cmd_code <= (others => '0');
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- AXI4-Lite slave
  ------------------------------------------------------------------------------
  s_axi_awready <= axi_awready;
  s_axi_wready  <= axi_wready;
  s_axi_bvalid  <= axi_bvalid;
  s_axi_bresp   <= "00";
  s_axi_arready <= axi_arready;
  s_axi_rvalid  <= axi_rvalid;
  s_axi_rresp   <= "00";
  s_axi_rdata   <= axi_rdata;

  wr_en <= axi_awready and s_axi_awvalid and axi_wready and s_axi_wvalid;
  rd_en <= axi_arready and s_axi_arvalid and (not axi_rvalid);

  -- Write address / data handshake
  write_proc : process(clk)
  begin
    if rising_edge(clk) then
      ctrl_inject_p <= '0';
      ctrl_clear_p  <= '0';

      -- awready: assert for one cycle when both AW and W are valid
      if axi_awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
        axi_awready <= '1';
      else
        axi_awready <= '0';
      end if;

      if axi_wready = '0' and s_axi_wvalid = '1' and s_axi_awvalid = '1' then
        axi_wready <= '1';
      else
        axi_wready <= '0';
      end if;

      -- Perform the write on the accepted beat
      if wr_en = '1' then
        case s_axi_awaddr(7 downto 2) is
          when "000100" =>                      -- 0x10 INJECT_ADDR
            inject_addr <= s_axi_wdata;
          when "000101" =>                      -- 0x14 CONTROL
            if s_axi_wdata(0) = '1' then ctrl_inject_p <= '1'; end if;
            if s_axi_wdata(1) = '1' then ctrl_clear_p  <= '1'; end if;
          when others => null;
        end case;
      end if;

      -- Write response
      if wr_en = '1' and axi_bvalid = '0' then
        axi_bvalid <= '1';
      elsif axi_bvalid = '1' and s_axi_bready = '1' then
        axi_bvalid <= '0';
      end if;

      if aresetn = '0' then
        axi_awready <= '0'; axi_wready <= '0'; axi_bvalid <= '0';
        inject_addr <= (others => '0');
      end if;
    end if;
  end process;

  -- Read address / data handshake
  read_proc : process(clk)
  begin
    if rising_edge(clk) then
      if axi_arready = '0' and s_axi_arvalid = '1' then
        axi_arready <= '1';
        axi_araddr  <= s_axi_araddr;
      else
        axi_arready <= '0';
      end if;

      if rd_en = '1' then
        axi_rvalid <= '1';
        case axi_araddr(7 downto 2) is
          when "000000" =>                      -- 0x00 STATUS
            -- [31:20]=0  [19:16]=state  [15:12]=sticky  [11:10]=0  [9:0]=live
            axi_rdata <= x"000" & state_code
                       & hb_to_sticky & uncorr_sticky & ess_sticky & corr_sticky
                       & "00"
                       & st_detect & st_diag & st_uncorr & st_ess
                       & st_inj & st_class & st_corr & st_obs
                       & st_init & hb_alive;
          when "000001" =>                      -- 0x04 CORR_COUNT
            axi_rdata <= std_logic_vector(corr_count);
          when "000010" =>                      -- 0x08 HB_COUNT
            axi_rdata <= std_logic_vector(hb_count);
          when "000011" =>                      -- 0x0C UNCORR_COUNT
            axi_rdata <= std_logic_vector(uncorr_count);
          when "000100" =>                      -- 0x10 INJECT_ADDR
            axi_rdata <= inject_addr;
          when "000110" =>                      -- 0x18 CTRL_STATUS
            -- [7:4]=state  [1]=inject_busy  [0]=command_busy
            axi_rdata <= x"000000" & state_code & "00" & inject_busy & cmd_busy;
          when others =>
            axi_rdata <= (others => '0');
        end case;
      elsif axi_rvalid = '1' and s_axi_rready = '1' then
        axi_rvalid <= '0';
      end if;

      if aresetn = '0' then
        axi_arready <= '0'; axi_rvalid <= '0'; axi_rdata <= (others => '0');
      end if;
    end if;
  end process;

end architecture rtl;

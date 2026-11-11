--------------------------------------------------------------------------------
-- axil_master_bridge.vhd  -  AUP Explorer production_test
--
-- Tiny AXI4-Lite MASTER that bridges the I2C slave to the SEM AXI peripheral
-- (sem_axi_status).  It continuously round-robin READS the SEM health registers
-- into a small cache, so an I2C read of 0x34 is served instantly from the cache
-- (no clock-stretching), exactly like sysmon_drp_reader does for SYSMON.  When
-- the I2C slave pulses inject_req / clear_req, the bridge issues a single AXI
-- WRITE to the SEM CONTROL register (0x14).
--
-- Cache -> I2C 8-byte map (byte0 = sem_data[63:56], MSB first):
--   0 live_status : {uncorr, essential, injection, classification,
--                    correction, observation, initialization, hb_alive}
--   1 flags       : {hb_to_sticky, uncorr_sticky, ess_sticky, corr_sticky,
--                    detect_only, diagnostic_scan, inject_busy, command_busy}
--   2,3 corr_count[15:0]      4,5 hb_count[15:0]
--   6 uncorr_count[7:0]       7 state_code (0..7)
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axil_master_bridge is
  port (
    clk        : in  std_logic;
    aresetn    : in  std_logic;

    -- control from the I2C slave (single-cycle pulses in this clk domain)
    inject_req : in  std_logic;
    clear_req  : in  std_logic;

    -- cached SEM status for the I2C slave (0x34 payload)
    sem_data   : out std_logic_vector(63 downto 0);

    -- AXI4-Lite master
    m_axi_awaddr  : out std_logic_vector(7 downto 0);
    m_axi_awvalid : out std_logic;
    m_axi_awready : in  std_logic;
    m_axi_wdata   : out std_logic_vector(31 downto 0);
    m_axi_wstrb   : out std_logic_vector(3 downto 0);
    m_axi_wvalid  : out std_logic;
    m_axi_wready  : in  std_logic;
    m_axi_bresp   : in  std_logic_vector(1 downto 0);
    m_axi_bvalid  : in  std_logic;
    m_axi_bready  : out std_logic;
    m_axi_araddr  : out std_logic_vector(7 downto 0);
    m_axi_arvalid : out std_logic;
    m_axi_arready : in  std_logic;
    m_axi_rdata   : in  std_logic_vector(31 downto 0);
    m_axi_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_rvalid  : in  std_logic;
    m_axi_rready  : out std_logic
  );
end entity axil_master_bridge;

architecture rtl of axil_master_bridge is

  type addr_arr is array (0 to 4) of std_logic_vector(7 downto 0);
  --        STATUS   CORR     HB       UNCORR   CTRL_STATUS
  constant ADDRS : addr_arr := (x"00", x"04", x"08", x"0C", x"18");

  type st_t is (M_SEL, M_AR, M_R, M_WR, M_WR_RESP);
  signal st  : st_t := M_SEL;
  signal idx : integer range 0 to 4 := 0;

  signal r_status, r_corr, r_hb, r_uncorr, r_ctrl : std_logic_vector(31 downto 0)
         := (others => '0');

  signal wr_pending : std_logic := '0';
  signal wr_data    : std_logic_vector(31 downto 0) := (others => '0');
  signal aw_done, w_done : std_logic := '0';

  signal arvalid_i, rready_i : std_logic := '0';
  signal awvalid_i, wvalid_i, bready_i : std_logic := '0';
  signal araddr_i : std_logic_vector(7 downto 0) := (others => '0');

begin

  m_axi_awaddr  <= x"14";                 -- CONTROL register
  m_axi_awvalid <= awvalid_i;
  m_axi_wdata   <= wr_data;
  m_axi_wstrb   <= "1111";
  m_axi_wvalid  <= wvalid_i;
  m_axi_bready  <= bready_i;
  m_axi_araddr  <= araddr_i;
  m_axi_arvalid <= arvalid_i;
  m_axi_rready  <= rready_i;

  -- Assemble the 8-byte I2C payload from the cached registers.
  sem_data <=
      r_status(7 downto 0)                                      -- byte0 live
    & (r_status(15 downto 12) & r_status(9 downto 8) & r_ctrl(1 downto 0)) -- byte1 flags
    & r_corr(15 downto 8) & r_corr(7 downto 0)                 -- byte2,3
    & r_hb(15 downto 8)   & r_hb(7 downto 0)                   -- byte4,5
    & r_uncorr(7 downto 0)                                     -- byte6
    & x"0" & r_status(19 downto 16);                           -- byte7 state

  process(clk)
  begin
    if rising_edge(clk) then
      -- latch write requests from the I2C side
      if inject_req = '1' then wr_pending <= '1'; wr_data(0) <= '1'; end if;
      if clear_req  = '1' then wr_pending <= '1'; wr_data(1) <= '1'; end if;

      case st is
        when M_SEL =>
          arvalid_i <= '0'; rready_i <= '0';
          awvalid_i <= '0'; wvalid_i <= '0'; bready_i <= '0';
          aw_done <= '0'; w_done <= '0';
          if wr_pending = '1' then
            awvalid_i <= '1'; wvalid_i <= '1';
            st <= M_WR;
          else
            araddr_i  <= ADDRS(idx);
            arvalid_i <= '1';
            st <= M_AR;
          end if;

        when M_AR =>
          if m_axi_arready = '1' then
            arvalid_i <= '0';
            rready_i  <= '1';
            st <= M_R;
          end if;

        when M_R =>
          if m_axi_rvalid = '1' then
            rready_i <= '0';
            case idx is
              when 0 => r_status <= m_axi_rdata;
              when 1 => r_corr   <= m_axi_rdata;
              when 2 => r_hb     <= m_axi_rdata;
              when 3 => r_uncorr <= m_axi_rdata;
              when others => r_ctrl <= m_axi_rdata;
            end case;
            if idx = 4 then idx <= 0; else idx <= idx + 1; end if;
            st <= M_SEL;
          end if;

        when M_WR =>
          if m_axi_awready = '1' then awvalid_i <= '0'; aw_done <= '1'; end if;
          if m_axi_wready  = '1' then wvalid_i  <= '0'; w_done  <= '1'; end if;
          if (aw_done = '1' or m_axi_awready = '1') and
             (w_done  = '1' or m_axi_wready  = '1') then
            bready_i   <= '1';
            wr_pending <= '0';
            wr_data    <= (others => '0');
            st <= M_WR_RESP;
          end if;

        when M_WR_RESP =>
          if m_axi_bvalid = '1' then
            bready_i <= '0';
            st <= M_SEL;
          end if;
      end case;

      if aresetn = '0' then
        st <= M_SEL; idx <= 0; wr_pending <= '0'; wr_data <= (others => '0');
        arvalid_i <= '0'; rready_i <= '0';
        awvalid_i <= '0'; wvalid_i <= '0'; bready_i <= '0';
        aw_done <= '0'; w_done <= '0';
      end if;
    end if;
  end process;

end architecture rtl;

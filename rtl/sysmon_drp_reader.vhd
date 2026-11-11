--------------------------------------------------------------------------------
-- sysmon_drp_reader.vhd  -  AUP Explorer production_test
--
-- Tiny DRP master that continuously reads the SYSMON status registers (via the
-- System Management Wizard's DRP port, NOT its I2C pad) and latches the raw
-- 16-bit channel values for prodtest_i2c_slave to publish over I2C.
--
-- DRP read: present daddr, pulse den for one dclk with dwe=0, wait drdy=1, then
-- do is valid.  Cycles temp -> VCCINT -> VCCAUX -> VBRAM forever.
--
-- Status-register map (UG580, UltraScale+ SYSMON, same as 7-series XADC):
--   0x00 temperature   0x01 VCCINT   0x02 VCCAUX   0x06 VBRAM
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sysmon_drp_reader is
  port (
    clk    : in  std_logic;                       -- same domain as dclk_in
    -- DRP port to the System Management Wizard
    den    : out std_logic;
    dwe    : out std_logic;
    daddr  : out std_logic_vector(7 downto 0);
    di     : out std_logic_vector(15 downto 0);
    do     : in  std_logic_vector(15 downto 0);
    drdy   : in  std_logic;
    -- Latched raw channel values (valid once each has been read at least once)
    temp   : out std_logic_vector(15 downto 0);
    vccint : out std_logic_vector(15 downto 0);
    vccaux : out std_logic_vector(15 downto 0);
    vbram  : out std_logic_vector(15 downto 0)
  );
end entity sysmon_drp_reader;

architecture rtl of sysmon_drp_reader is
  type   addr_arr is array (0 to 3) of std_logic_vector(7 downto 0);
  constant ADDRS : addr_arr := (x"00", x"01", x"02", x"06");  -- temp,vccint,vccaux,vbram
  type   st_t is (SETUP, WAITRDY);
  signal st   : st_t := SETUP;
  signal ch   : integer range 0 to 3 := 0;   -- channel being issued now
  signal tmo  : integer range 0 to 2047 := 0; -- WAITRDY timeout counter
  signal rtemp, rvccint, rvccaux, rvbram : std_logic_vector(15 downto 0) := (others => '0');
begin

  di     <= (others => '0');          -- reads only
  temp   <= rtemp;
  vccint <= rvccint;
  vccaux <= rvccaux;
  vbram  <= rvbram;

  process(clk)
  begin
    if rising_edge(clk) then
      den <= '0';
      dwe <= '0';
      case st is
        when SETUP =>
          daddr <= ADDRS(ch);
          den   <= '1';               -- single-cycle read strobe
          tmo   <= 0;
          st    <= WAITRDY;
        when WAITRDY =>
          -- On this silicon the DRP returns 'do' with its own drdy (verified by
          -- ILA capture), so store the current channel's result directly.
          if drdy = '1' then
            case ch is
              when 0 => rtemp   <= do;
              when 1 => rvccint <= do;
              when 2 => rvccaux <= do;
              when others => rvbram <= do;
            end case;
            if ch = 3 then ch <= 0; else ch <= ch + 1; end if;
            st <= SETUP;
          elsif tmo = 2000 then
            -- No drdy (e.g. the read was issued during SYSMON reset): re-issue
            -- the same channel rather than hang forever.
            st <= SETUP;
          else
            tmo <= tmo + 1;
          end if;
      end case;
    end if;
  end process;

end architecture rtl;

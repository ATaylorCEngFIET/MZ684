--------------------------------------------------------------------------------
-- tb_sysmon_ip.vhd  -  run sysmon_drp_reader against the REAL System Management
-- Wizard IP behavioral model, to observe the DRP den/drdy handshake.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_sysmon_ip is
end entity;

architecture sim of tb_sysmon_ip is
  signal clk  : std_logic := '0';
  signal den, dwe, drdy : std_logic;
  signal daddr : std_logic_vector(7 downto 0);
  signal di, do : std_logic_vector(15 downto 0);
  signal temp, vccint, vccaux, vbram : std_logic_vector(15 downto 0);

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
  end component;

  signal den_cnt, drdy_cnt : integer := 0;
  signal rst_cnt    : unsigned(8 downto 0) := (others => '0');
  signal sysmon_rst : std_logic := '1';
begin
  clk <= not clk after 5 ns;   -- 100 MHz

  reset_proc : process(clk)
  begin
    if rising_edge(clk) then
      if rst_cnt(8) = '0' then rst_cnt <= rst_cnt + 1; end if;
      sysmon_rst <= not rst_cnt(8);
    end if;
  end process;

  u_ip : sysmon_drp
    port map (
      di_in => di, daddr_in => daddr, den_in => den, dwe_in => dwe,
      drdy_out => drdy, do_out => do, dclk_in => clk, reset_in => sysmon_rst,
      user_temp_alarm_out => open, vccint_alarm_out => open,
      vccaux_alarm_out => open, ot_out => open, channel_out => open,
      eoc_out => open, alarm_out => open, eos_out => open, busy_out => open);

  u_reader : entity work.sysmon_drp_reader
    port map (clk => clk, den => den, dwe => dwe, daddr => daddr,
              di => di, do => do, drdy => drdy,
              temp => temp, vccint => vccint, vccaux => vccaux, vbram => vbram);

  mon : process(clk)
  begin
    if rising_edge(clk) then
      if den  = '1' then den_cnt  <= den_cnt  + 1; end if;
      if drdy = '1' then drdy_cnt <= drdy_cnt + 1; end if;
    end if;
  end process;

  check : process
    variable L : line;
  begin
    wait for 60 us;      -- allow SYSMON init + several DRP reads
    write(L, string'("den pulses="));  write(L, den_cnt);
    write(L, string'("  drdy pulses=")); write(L, drdy_cnt);
    writeline(output, L);
    write(L, string'("regs: temp="));   hwrite(L, temp);
    write(L, string'(" vccint=")); hwrite(L, vccint);
    write(L, string'(" vccaux=")); hwrite(L, vccaux);
    write(L, string'(" vbram="));  hwrite(L, vbram);
    writeline(output, L);
    if drdy_cnt = 0 then
      report "NO DRDY: the IP never acknowledged a DRP read (handshake problem)" severity note;
    else
      report "DRDY seen: reader+IP handshake works in sim" severity note;
    end if;
    std.env.stop;
  end process;

end architecture sim;

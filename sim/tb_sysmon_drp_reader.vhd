--------------------------------------------------------------------------------
-- tb_sysmon_drp_reader.vhd  -  self-checking testbench for sysmon_drp_reader
--
-- A tiny DRP responder stub answers each read with a value keyed to daddr, a
-- few cycles after den.  After the reader has cycled all four channels, the
-- latched outputs must equal the per-address values.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_sysmon_drp_reader is
end entity;

architecture sim of tb_sysmon_drp_reader is
  signal clk  : std_logic := '0';
  signal den, dwe, drdy : std_logic;
  signal daddr : std_logic_vector(7 downto 0);
  signal di, do : std_logic_vector(15 downto 0);
  signal temp, vccint, vccaux, vbram : std_logic_vector(15 downto 0);

  -- per-address canned DRP data
  function drp_val(a : std_logic_vector(7 downto 0)) return std_logic_vector is
  begin
    case a is
      when x"00"   => return x"AAA0";   -- temp
      when x"01"   => return x"BBB1";   -- vccint
      when x"02"   => return x"CCC2";   -- vccaux
      when others  => return x"DDD6";   -- vbram (0x06)
    end case;
  end function;

  signal pend : integer range 0 to 7 := 0;
  signal lad  : std_logic_vector(7 downto 0) := (others => '0');
begin
  clk <= not clk after 5 ns;

  dut : entity work.sysmon_drp_reader
    port map (clk => clk, den => den, dwe => dwe, daddr => daddr,
              di => di, do => do, drdy => drdy,
              temp => temp, vccint => vccint, vccaux => vccaux, vbram => vbram);

  -- DRP responder: 3-cycle latency, one-cycle drdy pulse with keyed data.
  stub : process(clk)
  begin
    if rising_edge(clk) then
      drdy <= '0';
      if den = '1' then
        lad  <= daddr;
        pend <= 3;
      elsif pend > 1 then
        pend <= pend - 1;
      elsif pend = 1 then
        pend <= 0;
        do   <= drp_val(lad);
        drdy <= '1';
      end if;
    end if;
  end process;

  check : process
    variable L : line;
  begin
    wait for 3 us;                      -- let all 4 channels be read
    write(L, string'("  temp="));   hwrite(L, temp);
    write(L, string'(" vccint=")); hwrite(L, vccint);
    write(L, string'(" vccaux=")); hwrite(L, vccaux);
    write(L, string'(" vbram="));  hwrite(L, vbram);
    writeline(output, L);
    assert temp   = x"AAA0" report "FAIL: temp"   severity failure;
    assert vccint = x"BBB1" report "FAIL: vccint" severity failure;
    assert vccaux = x"CCC2" report "FAIL: vccaux" severity failure;
    assert vbram  = x"DDD6" report "FAIL: vbram"  severity failure;
    report "PASS: DRP reader latched all 4 channels" severity note;
    report "ALL TESTS PASSED" severity note;
    std.env.stop;
  end process;

end architecture sim;

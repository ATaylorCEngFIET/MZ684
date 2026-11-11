--------------------------------------------------------------------------------
-- tb_prodtest_i2c_slave.vhd  -  self-checking testbench for prodtest_i2c_slave
--
-- I2C master on a weak-pull-up bus checks the combined two-address slave:
--   1. READ 0x33 -> 12 DNA bytes == DNA_SIM_VALUE (MSB first).
--   2. READ 0x32 -> 8 SYSMON bytes == injected sysmon_data (temp,VCCINT,
--      VCCAUX,VBRAM), MSB first.
--   3. READ an unrelated address (0x30) -> NOT ACKed (no collision).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_prodtest_i2c_slave is
end entity;

architecture sim of tb_prodtest_i2c_slave is

  constant DNA_PATTERN : std_logic_vector(95 downto 0) := X"A5A5012345678000CDEF1234";
  -- temp=1234 VCCINT=5678 VCCAUX=9ABC VBRAM=DEF0
  constant SYSMON_DATA : std_logic_vector(63 downto 0) := X"123456789ABCDEF0";

  signal clk     : std_logic := '0';
  signal scl_bus : std_logic;
  signal sda_bus : std_logic;
  signal m_scl   : std_logic := 'Z';
  signal m_sda   : std_logic := 'Z';
  signal sda_oe  : std_logic;

  constant TCLK : time := 10 ns;
  constant TQ   : time := 250 ns;

begin
  clk <= not clk after TCLK/2;

  scl_bus <= 'H';
  sda_bus <= 'H';
  scl_bus <= m_scl;
  sda_bus <= m_sda;
  sda_bus <= '0' when sda_oe = '1' else 'Z';

  dut : entity work.prodtest_i2c_slave
    generic map (
      DNA_ADDR      => "0110011",       -- 0x33
      SYSMON_ADDR   => "0110010",       -- 0x32
      DNA_SIM_VALUE => DNA_PATTERN
    )
    port map (
      clk         => clk,
      scl_i       => scl_bus,
      sda_i       => sda_bus,
      sda_oe      => sda_oe,
      sysmon_data => SYSMON_DATA
    );

  stim : process
    type byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);
    variable rx   : byte_arr(0 to 11);
    variable ackb : std_logic;
    variable L    : line;

    procedure i2c_start is
    begin
      m_sda <= 'Z'; m_scl <= 'Z'; wait for TQ;
      m_sda <= '0';                 wait for TQ;
      m_scl <= '0';                 wait for TQ;
    end procedure;

    procedure i2c_stop is
    begin
      m_sda <= '0'; wait for TQ;
      m_scl <= 'Z'; wait for TQ;
      m_sda <= 'Z'; wait for TQ;
    end procedure;

    procedure wr_bit(b : std_logic) is
    begin
      if b = '0' then m_sda <= '0'; else m_sda <= 'Z'; end if;
      wait for TQ;
      m_scl <= 'Z'; wait for 2*TQ;
      m_scl <= '0'; wait for TQ;
    end procedure;

    procedure rd_bit(signal s : in std_logic; b : out std_logic) is
    begin
      m_sda <= 'Z'; wait for TQ;
      m_scl <= 'Z'; wait for TQ;
      b := to_X01(s);
      wait for TQ;
      m_scl <= '0'; wait for TQ;
    end procedure;

    procedure wr_byte(d : std_logic_vector(7 downto 0); ack : out std_logic) is
    begin
      for i in 7 downto 0 loop wr_bit(d(i)); end loop;
      rd_bit(sda_bus, ack);
    end procedure;

    procedure rd_byte(d : out std_logic_vector(7 downto 0); master_ack : std_logic) is
      variable bv  : std_logic;
      variable tmp : std_logic_vector(7 downto 0);
    begin
      for i in 7 downto 0 loop rd_bit(sda_bus, bv); tmp(i) := bv; end loop;
      d := tmp;
      wr_bit(master_ack);
    end procedure;

    -- Read 'n' bytes from 'addr7' into rx, check against 'expect' (n*8 bits, MSB first).
    procedure check_read(addr7 : std_logic_vector(6 downto 0); n : integer;
                         expect : std_logic_vector; tag : string) is
      variable ab : std_logic;
      variable exp_byte : std_logic_vector(7 downto 0);
      variable ok : boolean := true;
    begin
      i2c_start;
      wr_byte(addr7 & '1', ab);           -- read transfer
      assert ab = '0' report "FAIL: " & tag & " not ACKed" severity failure;
      for i in 0 to n-1 loop
        if i < n-1 then rd_byte(rx(i), '0'); else rd_byte(rx(i), '1'); end if;
      end loop;
      i2c_stop;
      write(L, string'("  " & tag & " bytes: "));
      for i in 0 to n-1 loop hwrite(L, rx(i)); write(L, string'(" ")); end loop;
      writeline(output, L);
      for i in 0 to n-1 loop
        exp_byte := expect(expect'high - i*8 downto expect'high - i*8 - 7);
        if rx(i) /= exp_byte then ok := false; end if;
      end loop;
      assert ok report "FAIL: " & tag & " payload mismatch" severity failure;
      report "PASS: " & tag & " read matches expected" severity note;
    end procedure;

  begin
    wait for 10 us;   -- let DNA capture finish

    check_read("0110011", 12, DNA_PATTERN, "DNA(0x33)");
    wait for 2 us;
    check_read("0110010", 8,  SYSMON_DATA, "SYSMON(0x32)");
    wait for 2 us;

    -- unrelated address 0x30 -> must NOT ACK
    i2c_start;
    wr_byte("0110000" & '1', ackb);
    assert ackb /= '0'
      report "FAIL: slave wrongly ACKed 0x30" severity failure;
    report "PASS: 0x30 not ACKed (no spurious match)" severity note;
    i2c_stop;

    report "ALL TESTS PASSED" severity note;
    wait for 1 us;
    std.env.stop;
  end process;

end architecture sim;

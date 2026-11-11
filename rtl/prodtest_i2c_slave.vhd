--------------------------------------------------------------------------------
-- prodtest_i2c_slave.vhd  -  AUP Explorer production_test
--
-- A single READ-ONLY I2C slave (one bus, one IOBUF on N4/R7) that answers TWO
-- addresses, so DNA and SYSMON share the scarce RP2040<->FPGA link pins:
--
--   0x33 (DNA_ADDR)    : 12 bytes = the 96-bit FPGA Device DNA, MSB first
--                        (byte0 = DNA[95:88] ... byte11 = DNA[7:0]).
--   0x32 (SYSMON_ADDR) :  8 bytes = SYSMON raw channels, each 16-bit MSB first,
--                        in order temp, VCCINT, VCCAUX, VBRAM.  These come in on
--                        sysmon_data, fed by sysmon_drp_reader (DRP, not I2C).
--
-- A plain read streams the selected payload MSB first, wrapping if the master
-- keeps clocking.  Writes are ACKed and ignored (no sub-address).  SCL is read
-- only (never clock-stretched).  Open-drain is expressed as sda_oe to the single
-- top-level IOBUF - there is no tristate in this module.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity prodtest_i2c_slave is
  generic (
    DNA_ADDR      : std_logic_vector(6 downto 0) := "0110011";  -- 0x33
    SYSMON_ADDR   : std_logic_vector(6 downto 0) := "0110010";  -- 0x32
    SEM_ADDR      : std_logic_vector(6 downto 0) := "0110100";  -- 0x34
    -- Simulation-only DNA pattern (ignored by the real DNA_PORTE2 in silicon).
    DNA_SIM_VALUE : std_logic_vector(95 downto 0) := X"A5A5012345678000CDEF1234"
  );
  port (
    clk         : in  std_logic;                      -- 100 MHz free-running
    scl_i       : in  std_logic;                      -- I2C clock (read-only)
    sda_i       : in  std_logic;                      -- I2C data readback
    sda_oe      : out std_logic;                      -- '1' => pull SDA low
    -- SYSMON raw channels {temp, VCCINT, VCCAUX, VBRAM}, each 16-bit, MSB in [63]
    sysmon_data : in  std_logic_vector(63 downto 0);
    -- SEM config-memory status cache (8 bytes), MSB in [63]; see axil_master_bridge
    sem_data    : in  std_logic_vector(63 downto 0);
    -- Single-cycle pulses when a write to SEM_ADDR carries bit0 / bit1 set.
    inject_req  : out std_logic;                      -- flip a config bit (test)
    clear_req   : out std_logic                       -- clear SEM counters/sticky
  );
end entity prodtest_i2c_slave;

architecture rtl of prodtest_i2c_slave is

  -- ---------------- DNA capture ----------------
  signal dna_dout  : std_logic;
  signal dna_read  : std_logic := '0';
  signal dna_shift : std_logic := '0';
  signal dna_reg   : std_logic_vector(95 downto 0) := (others => '0');
  type   dstate_t  is (D_SETTLE, D_READ, D_CAP, D_DONE);
  signal dstate    : dstate_t := D_SETTLE;
  signal dcnt      : integer range 0 to 127 := 0;

  -- ---------------- I2C input sync + edge detect ----------------
  signal scl_r  : std_logic_vector(2 downto 0) := "111";
  signal sda_r  : std_logic_vector(2 downto 0) := "111";
  signal scl_rise, scl_fall : std_logic;
  signal sda_rise, sda_fall : std_logic;
  signal start_cond, stop_cond : std_logic;

  -- ---------------- I2C slave FSM ----------------
  type istate_t is (I_IDLE, I_ADDR, I_ADDR_ACK, I_SEND, I_SEND_ACK,
                    I_WR_ACK, I_WDATA, I_WDATA_ACK);
  signal istate     : istate_t := I_IDLE;
  signal bitc       : integer range 0 to 8 := 0;
  signal sh_in      : std_logic_vector(7 downto 0) := (others => '0');
  signal sh_out     : std_logic_vector(7 downto 0) := (others => '0');
  signal byte_i     : integer range 0 to 11 := 0;
  signal plen       : integer range 1 to 12 := 12;   -- active payload length
  signal sel2       : std_logic_vector(1 downto 0) := "00"; -- 00=DNA 01=SYSMON 10=SEM
  signal pull_low   : std_logic := '0';
  signal ack_wait   : std_logic := '0';
  signal wack_ph    : std_logic := '0';              -- write-ACK phase flag

  -- Payload byte selector: DNA (idx 0..11), SYSMON or SEM (idx 0..7), all MSB first.
  function payload_byte(sel : std_logic_vector(1 downto 0);
                        dna : std_logic_vector(95 downto 0);
                        sm  : std_logic_vector(63 downto 0);
                        se  : std_logic_vector(63 downto 0);
                        idx : integer) return std_logic_vector is
  begin
    case sel is
      when "00"   => return dna(95 - idx*8 downto 88 - idx*8);
      when "01"   => return sm(63 - idx*8 downto 56 - idx*8);
      when others => return se(63 - idx*8 downto 56 - idx*8);
    end case;
  end function;

begin

  -- Open-drain SDA: just an enable to the top-level IOBUF (no tristate here).
  sda_oe <= pull_low;

  ----------------------------------------------------------------------------
  -- DNA_PORTE2 : read the 96-bit Device DNA once after configuration.
  ----------------------------------------------------------------------------
  u_dna : DNA_PORTE2
    generic map (
      SIM_DNA_VALUE => DNA_SIM_VALUE   -- simulation only; ignored in silicon
    )
    port map (
      DOUT  => dna_dout,
      DIN   => '0',
      READ  => dna_read,
      SHIFT => dna_shift,
      CLK   => clk
    );

  dna_proc : process(clk)
  begin
    if rising_edge(clk) then
      dna_read  <= '0';
      dna_shift <= '0';
      case dstate is
        when D_SETTLE =>
          if dcnt = 63 then
            dcnt <= 0; dna_read <= '1'; dstate <= D_READ;
          else
            dcnt <= dcnt + 1;
          end if;
        when D_READ =>
          -- READ high this cycle loads the register; DOUT = DNA[0] next cycle
          -- (model shifts LSB first).  Pre-assert SHIFT (it is registered).
          dna_shift <= '1';
          dcnt      <= 0;
          dstate    <= D_CAP;
        when D_CAP =>
          -- DOUT presents DNA[0..95]; shift LSB-first into the MSB end so after
          -- 96 captures dna_reg = DNA[95:0] (== SIM_DNA_VALUE).
          dna_reg <= dna_dout & dna_reg(95 downto 1);
          if dcnt = 95 then
            dstate <= D_DONE;
          else
            dna_shift <= '1';
            dcnt      <= dcnt + 1;
          end if;
        when D_DONE =>
          null;
      end case;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Synchronize SCL/SDA to clk and detect edges + START/STOP.
  ----------------------------------------------------------------------------
  sync_proc : process(clk)
  begin
    if rising_edge(clk) then
      -- to_X01 maps a sim pull-up 'H'->'1'; a no-op on clean silicon levels.
      scl_r <= scl_r(1 downto 0) & to_X01(scl_i);
      sda_r <= sda_r(1 downto 0) & to_X01(sda_i);
    end if;
  end process;

  scl_rise <= '1' when (scl_r(2) = '0' and scl_r(1) = '1') else '0';
  scl_fall <= '1' when (scl_r(2) = '1' and scl_r(1) = '0') else '0';
  sda_rise <= '1' when (sda_r(2) = '0' and sda_r(1) = '1') else '0';
  sda_fall <= '1' when (sda_r(2) = '1' and sda_r(1) = '0') else '0';
  start_cond <= '1' when (sda_fall = '1' and scl_r(1) = '1') else '0';
  stop_cond  <= '1' when (sda_rise = '1' and scl_r(1) = '1') else '0';

  ----------------------------------------------------------------------------
  -- I2C slave state machine.
  ----------------------------------------------------------------------------
  i2c_proc : process(clk)
  begin
    if rising_edge(clk) then
      inject_req <= '0';                  -- single-cycle command pulses
      clear_req  <= '0';
      if start_cond = '1' then
        istate   <= I_ADDR;
        bitc     <= 0;
        pull_low <= '0';
        wack_ph  <= '0';
      elsif stop_cond = '1' then
        istate   <= I_IDLE;
        pull_low <= '0';
        wack_ph  <= '0';
      else
        case istate is

          when I_IDLE =>
            pull_low <= '0';

          when I_ADDR =>                      -- shift in 8 bits (addr + R/W)
            pull_low <= '0';
            if scl_rise = '1' then
              sh_in <= sh_in(6 downto 0) & sda_r(1);
              if bitc = 7 then
                bitc <= 0;
                istate <= I_ADDR_ACK;
              else
                bitc <= bitc + 1;
              end if;
            end if;

          when I_ADDR_ACK =>                  -- ACK + set up the matched payload
            if scl_fall = '1' then
              if sh_in(7 downto 1) = DNA_ADDR then
                pull_low <= '1';               -- ACK
                if sh_in(0) = '1' then
                  sel2 <= "00"; plen <= 12; byte_i <= 0;
                  sh_out <= payload_byte("00", dna_reg, sysmon_data, sem_data, 0);
                  istate <= I_SEND;
                else
                  istate <= I_IDLE;            -- write: ACK then ignore
                end if;
              elsif sh_in(7 downto 1) = SYSMON_ADDR then
                pull_low <= '1';               -- ACK
                if sh_in(0) = '1' then
                  sel2 <= "01"; plen <= 8; byte_i <= 0;
                  sh_out <= payload_byte("01", dna_reg, sysmon_data, sem_data, 0);
                  istate <= I_SEND;
                else
                  istate <= I_IDLE;
                end if;
              elsif sh_in(7 downto 1) = SEM_ADDR then
                pull_low <= '1';               -- ACK
                if sh_in(0) = '1' then
                  sel2 <= "10"; plen <= 8; byte_i <= 0;
                  sh_out <= payload_byte("10", dna_reg, sysmon_data, sem_data, 0);
                  istate <= I_SEND;
                else
                  wack_ph <= '0';              -- write: ACK the address first,
                  istate  <= I_WR_ACK;         -- release at the ACK clock, then RX
                end if;
              else
                pull_low <= '0';               -- not us -> NACK (release)
                istate   <= I_IDLE;
              end if;
              bitc <= 0;
            end if;

          when I_SEND =>                       -- shift out 8 bits MSB-first
            if scl_fall = '1' then
              pull_low <= not sh_out(7);
              sh_out   <= sh_out(6 downto 0) & '0';
              if bitc = 7 then
                bitc     <= 0;
                ack_wait <= '0';
                istate   <= I_SEND_ACK;
              else
                bitc <= bitc + 1;
              end if;
            end if;

          when I_SEND_ACK =>                   -- read master ACK/NACK, wrap on plen
            if scl_fall = '1' then
              pull_low <= '0';
              ack_wait <= '1';
            elsif scl_rise = '1' and ack_wait = '1' then
              if sda_r(1) = '0' then           -- ACK -> next byte (wrap at plen)
                if byte_i = plen - 1 then byte_i <= 0; else byte_i <= byte_i + 1; end if;
                sh_out <= payload_byte(sel2, dna_reg, sysmon_data, sem_data,
                                       (byte_i + 1) mod plen);
                istate <= I_SEND;
              else                             -- NACK -> done
                istate <= I_IDLE;
              end if;
            end if;

          when I_WR_ACK =>                     -- hold the address ACK through its
            if scl_fall = '1' then             -- clock, release, then receive data
              pull_low <= '0';
              bitc     <= 0;
              istate   <= I_WDATA;
            end if;

          when I_WDATA =>                      -- receive one command byte (SEM write)
            if scl_rise = '1' then
              sh_in <= sh_in(6 downto 0) & sda_r(1);
              if bitc = 7 then
                bitc    <= 0;
                wack_ph <= '0';
                istate  <= I_WDATA_ACK;
              else
                bitc <= bitc + 1;
              end if;
            end if;

          when I_WDATA_ACK =>                  -- ACK the byte, act on the command
            if scl_fall = '1' and wack_ph = '0' then
              pull_low <= '1';                 -- drive ACK low through the 9th clock
              wack_ph  <= '1';
              inject_req <= sh_in(0);          -- bit0 = inject, bit1 = clear
              clear_req  <= sh_in(1);
            elsif scl_fall = '1' and wack_ph = '1' then
              pull_low <= '0';                 -- release after the ACK clock
              wack_ph  <= '0';
              istate   <= I_WDATA;             -- accept a further byte if any
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;

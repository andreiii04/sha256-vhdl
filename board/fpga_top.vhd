-- EXAMPLE board top (untested on hardware): Xilinx 7-series board with a
-- 100 MHz oscillator and an active-low reset button, e.g. Arty A7.
-- Adapt the clock generation and reset polarity to your board; see
-- board/README.md. Pins are assigned in template.xdc.
--
-- MMCM: 100 MHz -> 50 MHz system clock. The core is not expected to meet
-- 100 MHz (its critical path is about 10.6 ns post-synthesis); 50 MHz
-- leaves margin. Reset is held until the MMCM locks, released synchronously.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library UNISIM;
use UNISIM.VCOMPONENTS.ALL;

entity fpga_top is
    port (
        clk100  : in  std_logic;
        rst_n   : in  std_logic;
        uart_rx : in  std_logic;
        uart_tx : out std_logic;
        led     : out std_logic_vector(3 downto 0)
    );
end fpga_top;

architecture rtl of fpga_top is

    signal clkfb, clkfb_buf : std_logic;
    signal clk50_unbuf      : std_logic;
    signal clk50            : std_logic;
    signal locked           : std_logic;
    signal rst_pipe         : std_logic_vector(2 downto 0) := (others => '1');
    signal rst              : std_logic;

begin

    mmcm_inst: MMCME2_BASE
        generic map (
            CLKIN1_PERIOD    => 10.0,   -- 100 MHz in
            DIVCLK_DIVIDE    => 1,
            CLKFBOUT_MULT_F  => 10.0,   -- VCO 1000 MHz
            CLKOUT0_DIVIDE_F => 20.0    -- 50 MHz out
        )
        port map (
            CLKIN1   => clk100,
            CLKFBIN  => clkfb_buf,
            RST      => '0',
            PWRDWN   => '0',
            CLKFBOUT => clkfb,
            CLKOUT0  => clk50_unbuf,
            LOCKED   => locked
        );

    fb_bufg:  BUFG port map (I => clkfb,       O => clkfb_buf);
    clk_bufg: BUFG port map (I => clk50_unbuf, O => clk50);

    -- Button and lock are asynchronous to clk50: 3-stage synchronizer
    process(clk50)
    begin
        if rising_edge(clk50) then
            rst_pipe <= rst_pipe(1 downto 0) & ((not rst_n) or (not locked));
        end if;
    end process;
    rst <= rst_pipe(2);

    app: entity work.sha256_uart_top
        generic map (CLK_HZ => 50_000_000, BAUD => 115_200)
        port map (clk => clk50, rst => rst, uart_rx => uart_rx, uart_tx => uart_tx, led => led);

end rtl;

-- UART receiver, 8 data bits, no parity, 1 stop bit (8N1), LSB first.
-- rx is synchronized internally. Each bit is sampled once, in its middle.
-- A byte is reported with a one-cycle valid pulse; a frame whose stop bit
-- is '0' is dropped.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_rx is
    generic (
        CLKS_PER_BIT : positive := 434   -- 50 MHz / 115200 baud
    );
    port (
        clk   : in  std_logic;
        rst   : in  std_logic;
        rx    : in  std_logic;
        data  : out std_logic_vector(7 downto 0);
        valid : out std_logic
    );
end uart_rx;

architecture rtl of uart_rx is

    type state_type is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state    : state_type := IDLE;
    signal rx_meta  : std_logic := '1';
    signal rx_sync  : std_logic := '1';
    signal clk_cnt  : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_idx  : integer range 0 to 7 := 0;
    signal shreg    : std_logic_vector(7 downto 0) := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then
            rx_meta <= rx;
            rx_sync <= rx_meta;
            valid   <= '0';

            if rst = '1' then
                state   <= IDLE;
                clk_cnt <= 0;
                bit_idx <= 0;
                data    <= (others => '0');
            else
                case state is
                    when IDLE =>
                        clk_cnt <= 0;
                        bit_idx <= 0;
                        if rx_sync = '0' then
                            state <= START_BIT;
                        end if;

                    -- Wait half a bit, then confirm the start bit is still low
                    when START_BIT =>
                        if clk_cnt = (CLKS_PER_BIT - 1) / 2 then
                            clk_cnt <= 0;
                            if rx_sync = '0' then
                                state <= DATA_BITS;
                            else
                                state <= IDLE;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when DATA_BITS =>
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            shreg   <= rx_sync & shreg(7 downto 1);
                            if bit_idx = 7 then
                                state <= STOP_BIT;
                            else
                                bit_idx <= bit_idx + 1;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when STOP_BIT =>
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            state   <= IDLE;
                            if rx_sync = '1' then
                                data  <= shreg;
                                valid <= '1';
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

end rtl;

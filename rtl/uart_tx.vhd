-- UART transmitter, 8N1, LSB first.
-- Valid/ready handshake: a byte is accepted on a rising edge where
-- valid = '1' and ready = '1'. ready is low while a frame is being sent.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_tx is
    generic (
        CLKS_PER_BIT : positive := 434   -- 50 MHz / 115200 baud
    );
    port (
        clk   : in  std_logic;
        rst   : in  std_logic;
        data  : in  std_logic_vector(7 downto 0);
        valid : in  std_logic;
        ready : out std_logic;
        tx    : out std_logic
    );
end uart_tx;

architecture rtl of uart_tx is

    signal busy    : std_logic := '0';
    -- stop bit & data & start bit, shifted out LSB first
    signal frame   : std_logic_vector(9 downto 0) := (others => '1');
    signal clk_cnt : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_cnt : integer range 0 to 9 := 0;

begin

    ready <= not busy;
    tx    <= frame(0);

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                busy    <= '0';
                frame   <= (others => '1');
                clk_cnt <= 0;
                bit_cnt <= 0;
            elsif busy = '0' then
                if valid = '1' then
                    frame   <= '1' & data & '0';
                    busy    <= '1';
                    clk_cnt <= 0;
                    bit_cnt <= 0;
                end if;
            else
                if clk_cnt = CLKS_PER_BIT - 1 then
                    clk_cnt <= 0;
                    if bit_cnt = 9 then
                        busy  <= '0';
                        frame <= (others => '1');
                    else
                        bit_cnt <= bit_cnt + 1;
                        frame   <= '1' & frame(9 downto 1);
                    end if;
                else
                    clk_cnt <= clk_cnt + 1;
                end if;
            end if;
        end if;
    end process;

end rtl;

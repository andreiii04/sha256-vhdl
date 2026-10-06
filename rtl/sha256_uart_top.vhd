-- Board-independent top level: SHA-256 over a UART link.
--
-- The wide parallel ports of sha256_single / sha256_double stay inside the
-- FPGA; only clk, rst, the two UART pins and 4 LEDs leave the chip.
--
-- Protocol (8N1, BAUD generic), host -> FPGA:
--   'S' <len> <len bytes>   SHA-256 of a 0..55 byte string
--   'B' <80 bytes>          Bitcoin double SHA-256 of a wire-format header
-- FPGA -> host:
--   'K' <32 bytes>          digest, first byte = most significant
--   'E'                     unknown command or len > 55
-- A frame that stalls for RX_TIMEOUT_MS is dropped (error LED, no reply).
--
-- LEDs: 0 heartbeat, 1 busy, 2 last command OK, 3 last command error.
-- rst is synchronous, active high, and must already be synchronized to clk.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sha256_uart_top is
    generic (
        CLK_HZ        : positive := 50_000_000;
        BAUD          : positive := 115_200;
        RX_TIMEOUT_MS : positive := 100
    );
    port (
        clk     : in  std_logic;
        rst     : in  std_logic;
        uart_rx : in  std_logic;
        uart_tx : out std_logic;
        led     : out std_logic_vector(3 downto 0)
    );
end sha256_uart_top;

architecture rtl of sha256_uart_top is

    constant CLKS_PER_BIT    : positive := CLK_HZ / BAUD;
    constant TIMEOUT_CYCLES  : positive := (CLK_HZ / 1000) * RX_TIMEOUT_MS;
    constant MAX_STRING_LEN  : integer  := 55;
    constant HEADER_LEN      : integer  := 80;

    type state_type is (CMD, RX_LEN, RX_STRING, ALIGN_STRING, RX_HEADER,
                        RUN_SINGLE, RUN_DOUBLE, SEND_STATUS, SEND_DIGEST);
    signal state : state_type := CMD;

    -- UART
    signal rx_data  : std_logic_vector(7 downto 0);
    signal rx_valid : std_logic;
    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid : std_logic := '0';
    signal tx_ready : std_logic;

    -- Frame assembly
    signal str_buf     : std_logic_vector(MAX_STRING_LEN * 8 - 1 downto 0) := (others => '0');
    signal str_len     : integer range 0 to MAX_STRING_LEN := 0;
    signal hdr_buf     : std_logic_vector(HEADER_LEN * 8 - 1 downto 0) := (others => '0');
    signal byte_cnt    : integer range 0 to HEADER_LEN := 0;
    signal idle_cnt    : integer range 0 to TIMEOUT_CYCLES := 0;

    -- Hash engines
    signal single_start : std_logic := '0';
    signal single_done  : std_logic;
    signal single_hash  : std_logic_vector(255 downto 0);
    signal double_start : std_logic := '0';
    signal double_done  : std_logic;
    signal double_hash  : std_logic_vector(255 downto 0);

    -- Reply
    signal digest   : std_logic_vector(255 downto 0) := (others => '0');
    signal status   : std_logic_vector(7 downto 0) := (others => '0');
    signal send_cnt : integer range 0 to 32 := 0;

    -- LEDs
    signal heartbeat : unsigned(25 downto 0) := (others => '0');
    signal led_ok    : std_logic := '0';
    signal led_err   : std_logic := '0';

begin

    rx_inst: entity work.uart_rx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (clk => clk, rst => rst, rx => uart_rx, data => rx_data, valid => rx_valid);

    tx_inst: entity work.uart_tx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (clk => clk, rst => rst, data => tx_data, valid => tx_valid, ready => tx_ready, tx => uart_tx);

    single_inst: entity work.sha256_single
        port map (
            clk          => clk,
            rst          => rst,
            start        => single_start,
            string_in    => str_buf,
            string_len   => str_len,
            padded_block => open,
            done         => single_done,
            hash_out     => single_hash
        );

    double_inst: entity work.sha256_double
        port map (
            clk          => clk,
            rst          => rst,
            start        => double_start,
            block_header => hdr_buf,
            done         => double_done,
            first_hash   => open,
            hash_out     => double_hash
        );

    led(0) <= heartbeat(heartbeat'high);
    led(1) <= '0' when state = CMD else '1';
    led(2) <= led_ok;
    led(3) <= led_err;

    process(clk)
    begin
        if rising_edge(clk) then
            heartbeat <= heartbeat + 1;

            if rst = '1' then
                state        <= CMD;
                tx_valid     <= '0';
                single_start <= '0';
                double_start <= '0';
                byte_cnt     <= 0;
                idle_cnt     <= 0;
                led_ok       <= '0';
                led_err      <= '0';
            else
                -- Inter-byte timeout while a frame is being received
                if state = RX_LEN or state = RX_STRING or state = RX_HEADER then
                    if rx_valid = '1' then
                        idle_cnt <= 0;
                    elsif idle_cnt = TIMEOUT_CYCLES then
                        idle_cnt <= 0;
                        led_ok   <= '0';
                        led_err  <= '1';
                        state    <= CMD;
                    else
                        idle_cnt <= idle_cnt + 1;
                    end if;
                else
                    idle_cnt <= 0;
                end if;

                case state is
                    when CMD =>
                        byte_cnt <= 0;
                        if rx_valid = '1' then
                            if rx_data = x"53" then          -- 'S'
                                state <= RX_LEN;
                            elsif rx_data = x"42" then       -- 'B'
                                state <= RX_HEADER;
                            else
                                status <= x"45";             -- 'E'
                                state  <= SEND_STATUS;
                            end if;
                        end if;

                    when RX_LEN =>
                        if rx_valid = '1' then
                            if unsigned(rx_data) > MAX_STRING_LEN then
                                status <= x"45";
                                state  <= SEND_STATUS;
                            else
                                str_len <= to_integer(unsigned(rx_data));
                                if rx_data = x"00" then
                                    state <= ALIGN_STRING;
                                else
                                    state <= RX_STRING;
                                end if;
                            end if;
                        end if;

                    -- Bytes are shifted in from the right...
                    when RX_STRING =>
                        if rx_valid = '1' then
                            str_buf <= str_buf(str_buf'high - 8 downto 0) & rx_data;
                            if byte_cnt = str_len - 1 then
                                byte_cnt <= str_len;
                                state    <= ALIGN_STRING;
                            else
                                byte_cnt <= byte_cnt + 1;
                            end if;
                        end if;

                    -- ...then shifted up until byte 0 sits at the top (left-aligned)
                    when ALIGN_STRING =>
                        if byte_cnt = MAX_STRING_LEN then
                            single_start <= '1';
                            state        <= RUN_SINGLE;
                        else
                            str_buf  <= str_buf(str_buf'high - 8 downto 0) & x"00";
                            byte_cnt <= byte_cnt + 1;
                        end if;

                    when RX_HEADER =>
                        if rx_valid = '1' then
                            hdr_buf <= hdr_buf(hdr_buf'high - 8 downto 0) & rx_data;
                            if byte_cnt = HEADER_LEN - 1 then
                                double_start <= '1';
                                state        <= RUN_DOUBLE;
                            else
                                byte_cnt <= byte_cnt + 1;
                            end if;
                        end if;

                    -- start is held until done, then released (wrapper handshake)
                    when RUN_SINGLE =>
                        if single_done = '1' then
                            single_start <= '0';
                            digest       <= single_hash;
                            status       <= x"4B";           -- 'K'
                            state        <= SEND_STATUS;
                        end if;

                    when RUN_DOUBLE =>
                        if double_done = '1' then
                            double_start <= '0';
                            digest       <= double_hash;
                            status       <= x"4B";
                            state        <= SEND_STATUS;
                        end if;

                    when SEND_STATUS =>
                        if tx_valid = '0' then
                            tx_data  <= status;
                            tx_valid <= '1';
                        elsif tx_ready = '1' then
                            tx_valid <= '0';
                            send_cnt <= 0;
                            if status = x"4B" then
                                led_ok  <= '1';
                                led_err <= '0';
                                state   <= SEND_DIGEST;
                            else
                                led_ok  <= '0';
                                led_err <= '1';
                                state   <= CMD;
                            end if;
                        end if;

                    when SEND_DIGEST =>
                        if tx_valid = '0' then
                            tx_data  <= digest(255 downto 248);
                            tx_valid <= '1';
                        elsif tx_ready = '1' then
                            tx_valid <= '0';
                            digest   <= digest(247 downto 0) & x"00";
                            if send_cnt = 31 then
                                state <= CMD;
                            else
                                send_cnt <= send_cnt + 1;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

end rtl;

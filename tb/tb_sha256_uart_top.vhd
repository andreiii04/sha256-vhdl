-- Self-checking testbench for sha256_uart_top: real 8N1 frames at 115200
-- baud, driven and decoded by a UART model in the testbench.
--   valid 'S' and 'B' commands (incl. 0 and 55 bytes, two real headers),
--   unknown command, length > 55, stalled frame (timeout) and recovery,
--   LED status.
-- Exits with a failure (non-zero status) if any check fails.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.ALL;

entity tb_sha256_uart_top is
end tb_sha256_uart_top;

architecture sim of tb_sha256_uart_top is

    constant CLK_HZ     : positive := 50_000_000;
    constant BAUD       : positive := 115_200;
    constant CLK_PERIOD : time := 1 sec / CLK_HZ;
    constant BIT_TIME   : time := 1 sec / BAUD;

    constant GENESIS : std_logic_vector(639 downto 0) :=
        x"0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c";
    constant BLOCK_125552 : std_logic_vector(639 downto 0) :=
        x"0100000081cd02ab7e569e8bcd9317e2fe99f2de44d49ab2b8851ba4a308000000000000e320b6c2fffc8d750423db8b1eb942ae710e951ed797f7affc8892b0f1fc122bc7f5d74df2b9441a42a14695";
    constant MAX_STR : string := "The quick brown fox jumps over the lazy dog 0123456789A";

    signal clk     : std_logic := '0';
    signal rst     : std_logic := '1';
    signal rx_line : std_logic := '1';   -- host -> FPGA
    signal tx_line : std_logic;          -- FPGA -> host
    signal led     : std_logic_vector(3 downto 0);
    signal running : boolean := true;

    -- Bytes decoded from tx_line by the receiver process
    type byte_array is array (0 to 1023) of std_logic_vector(7 downto 0);
    signal rx_fifo     : byte_array;
    signal rx_count    : natural := 0;
    signal rx_framing  : natural := 0;   -- stop-bit errors seen

begin

    dut: entity work.sha256_uart_top
        generic map (CLK_HZ => CLK_HZ, BAUD => BAUD, RX_TIMEOUT_MS => 1)
        port map (clk => clk, rst => rst, uart_rx => rx_line, uart_tx => tx_line, led => led);

    clk <= not clk after CLK_PERIOD / 2 when running;

    -- UART receiver model: decode every frame on tx_line into rx_fifo
    receiver: process
        variable b : std_logic_vector(7 downto 0);
    begin
        wait until tx_line = '0';
        wait for BIT_TIME / 2;
        if tx_line = '0' then
            for i in 0 to 7 loop
                wait for BIT_TIME;
                b(i) := tx_line;
            end loop;
            wait for BIT_TIME;
            if tx_line /= '1' then
                rx_framing <= rx_framing + 1;
            end if;
            rx_fifo(rx_count) <= b;
            rx_count <= rx_count + 1;
        end if;
    end process;

    stimulus: process
        variable errors : natural := 0;
        variable checks : natural := 0;
        variable rd_idx : natural := 0;

        procedure check(ok : boolean; name : string) is
        begin
            checks := checks + 1;
            if ok then
                report "PASS " & name;
            else
                errors := errors + 1;
                report "FAIL " & name severity error;
            end if;
        end procedure;

        procedure send_byte(b : std_logic_vector(7 downto 0)) is
        begin
            rx_line <= '0';
            wait for BIT_TIME;
            for i in 0 to 7 loop
                rx_line <= b(i);
                wait for BIT_TIME;
            end loop;
            rx_line <= '1';
            wait for BIT_TIME;
        end procedure;

        procedure send_char(c : character) is
        begin
            send_byte(std_logic_vector(to_unsigned(character'pos(c), 8)));
        end procedure;

        -- Take the next byte from the receiver; ok = false on timeout
        procedure recv_byte(b : out std_logic_vector(7 downto 0); ok : out boolean) is
        begin
            if rx_count <= rd_idx then
                wait until rx_count > rd_idx for 4 ms;
            end if;
            if rx_count > rd_idx then
                b := rx_fifo(rd_idx);
                rd_idx := rd_idx + 1;
                ok := true;
            else
                b := (others => '0');
                ok := false;
            end if;
        end procedure;

        -- Read 'K' + 32 digest bytes, compare with expected
        procedure expect_digest(expected : std_logic_vector(255 downto 0); name : string) is
            variable b      : std_logic_vector(7 downto 0);
            variable ok     : boolean;
            variable all_ok : boolean := true;
            variable got    : std_logic_vector(255 downto 0);
        begin
            recv_byte(b, ok);
            check(ok and b = x"4B", name & ": status 'K'");
            for i in 0 to 31 loop
                recv_byte(b, ok);
                all_ok := all_ok and ok;
                got(255 - 8 * i downto 248 - 8 * i) := b;
            end loop;
            check(all_ok and got = expected, name & ": digest");
        end procedure;

        procedure expect_error(name : string) is
            variable b  : std_logic_vector(7 downto 0);
            variable ok : boolean;
        begin
            recv_byte(b, ok);
            check(ok and b = x"45", name & ": status 'E'");
        end procedure;

        procedure hash_string(s : string) is
        begin
            send_char('S');
            send_byte(std_logic_vector(to_unsigned(s'length, 8)));
            for i in s'range loop
                send_char(s(i));
            end loop;
        end procedure;

        procedure hash_header(h : std_logic_vector(639 downto 0)) is
        begin
            send_char('B');
            for i in 0 to 79 loop
                send_byte(h(639 - 8 * i downto 632 - 8 * i));
            end loop;
        end procedure;

    begin
        rst <= '1';
        wait for 20 * CLK_PERIOD;
        rst <= '0';
        wait for 20 * CLK_PERIOD;

        hash_string("abc");
        expect_digest(x"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "S abc");
        check(led(2) = '1' and led(3) = '0', "LED ok after good command");

        hash_string("");
        expect_digest(x"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "S empty");

        hash_string(MAX_STR);
        expect_digest(x"ac3bd9bcdd4d3996df77c00bce4deed0b462095c27cedc0a2f23ff5ad6238cfa", "S 55 bytes");

        hash_header(GENESIS);
        expect_digest(x"6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000", "B genesis");

        hash_header(BLOCK_125552);
        expect_digest(x"1dbd981fe6985776b644b173a4d0385ddc1aa2a829688d1e0000000000000000", "B block 125552");

        send_char('X');
        expect_error("unknown command");
        check(led(2) = '0' and led(3) = '1', "LED error after bad command");

        send_char('S');
        send_byte(x"38");   -- 56
        expect_error("length 56");

        -- Stalled frame: 2 of 5 bytes, then silence longer than the timeout
        send_char('S');
        send_byte(x"05");
        send_char('a');
        send_char('b');
        wait for 2 ms;
        check(led(1) = '0' and led(3) = '1', "stalled frame dropped after timeout");

        hash_string("hello");
        expect_digest(x"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", "S hello after timeout");
        check(led(2) = '1' and led(3) = '0', "LED ok again after recovery");

        wait for 1 ms;
        check(rx_count = rd_idx, "no unexpected reply bytes");
        check(rx_framing = 0, "no framing errors on tx");

        running <= false;
        if errors = 0 then
            report "RESULT tb_sha256_uart_top: PASS (" & integer'image(checks) & " checks)";
            finish;
        else
            report "RESULT tb_sha256_uart_top: FAIL (" & integer'image(errors) & " of " & integer'image(checks) & " checks)" severity failure;
        end if;
        wait;
    end process;

end sim;

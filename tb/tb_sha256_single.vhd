-- Self-checking testbench for sha256_single.
--   1. Known-answer vectors (padding and hash), including 0, 54 and 55 bytes
--   2. Handshake: start held high, back-to-back, start while busy, reset mid-hash
-- Exits with a failure (non-zero status) if any check fails.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.ALL;

entity tb_sha256_single is
end tb_sha256_single;

architecture sim of tb_sha256_single is

    constant MAX_STRING_LEN : integer := 55;
    constant STRING_WIDTH   : integer := MAX_STRING_LEN * 8;
    constant CLK_PERIOD     : time := 10 ns;
    constant TIMEOUT_CYCLES : integer := 200;

    -- Left-align an ASCII string into the string_in format (byte 0 at the top)
    function to_slv(s : string; n : integer) return std_logic_vector is
        variable r : std_logic_vector(STRING_WIDTH - 1 downto 0) := (others => '0');
    begin
        for i in 1 to n loop
            r(STRING_WIDTH - 1 - (i - 1) * 8 downto STRING_WIDTH - i * 8) :=
                std_logic_vector(to_unsigned(character'pos(s(i)), 8));
        end loop;
        return r;
    end function;

    type test_vector is record
        input_string    : string(1 to MAX_STRING_LEN);
        str_length      : integer range 0 to MAX_STRING_LEN;
        expected_padded : std_logic_vector(511 downto 0);
        expected_hash   : std_logic_vector(255 downto 0);
    end record;
    type test_vector_array is array (natural range <>) of test_vector;

    -- Expected values are cross-checked against hashlib by scripts/check_vectors.py
    constant TEST_VECTORS : test_vector_array := (
        (input_string => "abc" & (4 to MAX_STRING_LEN => ' '),
         str_length => 3,
         expected_padded => x"61626380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018",
         expected_hash => x"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (input_string => (1 to MAX_STRING_LEN => ' '),
         str_length => 0,
         expected_padded => x"80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
         expected_hash => x"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (input_string => "hello" & (6 to MAX_STRING_LEN => ' '),
         str_length => 5,
         expected_padded => x"68656C6C6F8000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000028",
         expected_hash => x"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"),
        (input_string => "a" & (2 to MAX_STRING_LEN => ' '),
         str_length => 1,
         expected_padded => x"61800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008",
         expected_hash => x"ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"),
        (input_string => "test" & (5 to MAX_STRING_LEN => ' '),
         str_length => 4,
         expected_padded => x"74657374800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020",
         expected_hash => x"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"),
        (input_string => "12345678!@#$%^&*()_+-=[]{}" & (27 to MAX_STRING_LEN => ' '),
         str_length => 26,
         expected_padded => x"313233343536373821402324255e262a28295f2b2d3d5b5d7b7d80000000000000000000000000000000000000000000000000000000000000000000000000d0",
         expected_hash => x"3b90101a027cc2f09b425487ca3e8e34eb2f586941ed5202cc0c35d9a7dd2bf8"),
        (input_string => "The quick brown fox jumps over the lazy dog 0123456789" & ' ',
         str_length => 54,
         expected_padded => x"54686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672030313233343536373839800000000000000001b0",
         expected_hash => x"b2b81446d25e39a4b840a79eeed4da1981eeae0a19329c0c58445022ccfa84bd"),
        (input_string => "The quick brown fox jumps over the lazy dog 0123456789A",
         str_length => 55,
         expected_padded => x"54686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672030313233343536373839418000000000000001b8",
         expected_hash => x"ac3bd9bcdd4d3996df77c00bce4deed0b462095c27cedc0a2f23ff5ad6238cfa")
    );

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal start        : std_logic := '0';
    signal string_in    : std_logic_vector(STRING_WIDTH - 1 downto 0) := (others => '0');
    signal string_len   : integer range 0 to MAX_STRING_LEN := 0;
    signal padded_block : std_logic_vector(511 downto 0);
    signal done         : std_logic;
    signal hash_out     : std_logic_vector(255 downto 0);
    signal running      : boolean := true;

begin

    dut: entity work.sha256_single
        port map (
            clk          => clk,
            rst          => rst,
            start        => start,
            string_in    => string_in,
            string_len   => string_len,
            padded_block => padded_block,
            done         => done,
            hash_out     => hash_out
        );

    clk <= not clk after CLK_PERIOD / 2 when running;

    stimulus: process
        variable errors : natural := 0;
        variable checks : natural := 0;
        variable cycles : natural;

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

        procedure tick(n : positive := 1) is
        begin
            for i in 1 to n loop
                wait until falling_edge(clk);
            end loop;
        end procedure;

        procedure load(v : test_vector) is
        begin
            string_in  <= to_slv(v.input_string, v.str_length);
            string_len <= v.str_length;
        end procedure;

        -- Wait (sampling on falling edges) until done = '1'; returns cycles waited
        procedure wait_done(variable n : out natural) is
        begin
            n := 0;
            while done /= '1' and n < TIMEOUT_CYCLES loop
                tick;
                n := n + 1;
            end loop;
        end procedure;

        procedure pulse_start is
        begin
            start <= '1';
            tick;
            start <= '0';
        end procedure;

    begin
        rst <= '1';
        tick(5);
        rst <= '0';
        tick;

        -- 1. Known-answer vectors
        for i in TEST_VECTORS'range loop
            load(TEST_VECTORS(i));
            pulse_start;
            wait_done(cycles);
            check(done = '1', "vector " & integer'image(i) & " completes");
            check(padded_block = TEST_VECTORS(i).expected_padded,
                  "vector " & integer'image(i) & " padding (" & integer'image(TEST_VECTORS(i).str_length) & " bytes)");
            check(hash_out = TEST_VECTORS(i).expected_hash,
                  "vector " & integer'image(i) & " hash");
            tick(3);
        end loop;
        report "INFO latency: start to done = " & integer'image(cycles + 1) & " cycles";

        -- 2a. start held high: one hash, done stays high until start is released
        load(TEST_VECTORS(0));
        start <= '1';
        wait_done(cycles);
        tick(10);
        check(done = '1' and hash_out = TEST_VECTORS(0).expected_hash, "start held: done stays high, hash correct");
        start <= '0';
        tick(2);
        check(done = '0', "start held: done clears after start drops");

        -- 2b. back-to-back: next start on the first cycle done is seen
        load(TEST_VECTORS(2));
        pulse_start;
        wait_done(cycles);
        load(TEST_VECTORS(1));
        pulse_start;
        wait_done(cycles);
        check(hash_out = TEST_VECTORS(1).expected_hash, "back-to-back: second hash correct");

        -- 2c. start while busy is ignored; inputs are sampled only at start
        tick(3);
        load(TEST_VECTORS(4));
        pulse_start;
        tick(20);
        load(TEST_VECTORS(3));
        pulse_start;
        wait_done(cycles);
        check(hash_out = TEST_VECTORS(4).expected_hash, "start while busy: ignored, first hash kept");
        tick;
        wait_done(cycles);
        check(done = '0', "start while busy: no second hash started");

        -- 2d. reset in the middle of a hash, then a clean hash
        load(TEST_VECTORS(5));
        pulse_start;
        tick(60);
        rst <= '1';
        tick;
        rst <= '0';
        check(done = '0', "reset mid-hash: done low");
        load(TEST_VECTORS(7));
        pulse_start;
        wait_done(cycles);
        check(hash_out = TEST_VECTORS(7).expected_hash, "reset mid-hash: next hash correct");

        -- Summary
        running <= false;
        if errors = 0 then
            report "RESULT tb_sha256_single: PASS (" & integer'image(checks) & " checks)";
            finish;
        else
            report "RESULT tb_sha256_single: FAIL (" & integer'image(errors) & " of " & integer'image(checks) & " checks)" severity failure;
        end if;
        wait;
    end process;

end sim;

-- Self-checking testbench for sha256_double (Bitcoin block-header hash).
--   1. Known-answer vectors: first hash and final hash, including two real
--      mainnet headers in wire byte order (Genesis, block 125552)
--   2. Handshake: start held high, back-to-back, reset mid-hash
-- Exits with a failure (non-zero status) if any check fails.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.ALL;

entity tb_sha256_double is
end tb_sha256_double;

architecture sim of tb_sha256_double is

    constant CLK_PERIOD     : time := 10 ns;
    constant TIMEOUT_CYCLES : integer := 600;

    -- Return the 32 digest bytes in reverse order (block explorer display order)
    function reverse_bytes(x : std_logic_vector(255 downto 0)) return std_logic_vector is
        variable r : std_logic_vector(255 downto 0);
    begin
        for i in 0 to 31 loop
            r(255 - 8 * i downto 248 - 8 * i) := x(8 * i + 7 downto 8 * i);
        end loop;
        return r;
    end function;

    type test_vector is record
        block_header   : std_logic_vector(639 downto 0);
        expected_first : std_logic_vector(255 downto 0);
        expected_final : std_logic_vector(255 downto 0);
    end record;
    type test_vector_array is array (natural range <>) of test_vector;

    -- Expected values are cross-checked against hashlib by scripts/check_vectors.py
    constant TEST_VECTORS : test_vector_array := (
        -- 0..4: synthetic headers (fixed patterns, all zeros, all ones)
        (block_header => x"010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000EFCDAB9078563412EFCDAB9078563412EFCDAB9078563412EFCDAB9078563412",
         expected_first => x"06F39847A4FA0755D2E9827A87BFBB08398F4ED795F2F8E1D50EC2909F02C1BE",
         expected_final => x"5AC9AE408A0BDC7CF52026DB8D9F306FE60174DCD2247890C035EFCE4F990E94"),
        (block_header => x"010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000EFCDAB9078563412EFCDAB9078563412EFCDAB9078563412EFCDAB9001000000",
         expected_first => x"A035473ED5A4904A83EBD9090F35389C1AD51BC773D765DDCCF8F3C684494590",
         expected_final => x"A831F3BC1A49A20F43C3E11D9DAD8EFE57C9DB72E6B23802C61D700325AD630E"),
        (block_header => x"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
         expected_first => x"5B6FB58E61FA475939767D68A446F97F1BFF02C0E5935A3EA8BB51E6515783D8",
         expected_final => x"4BE7570E8F70EB093640C8468274BA759745A7AA2B7D25AB1E0421B259845014"),
        (block_header => x"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
         expected_first => x"6D92A8EA911D0D96DAD7F2D76F2647E8B612E645140157668298DB20A9412D4B",
         expected_final => x"0DD0BD22F9F1445FAA5E0BDA81D21489A7F69CDD9DF8EC47675A57B849325DDB"),
        -- Block 125552 fields in display byte order with nonce 0: NOT a valid
        -- wire-format header; used here only as a generic 80-byte vector
        (block_header => x"0100000000000000000008a3a41b85b8b29ad444def299fee21793cd8b9e567eab02cd812b12fcf1b09288fcaff797d71e950e71ae42b91e8bdb2304758dfcffc2b620e3c7f5d74df2b9441a00000000",
         expected_first => x"BF40CE5F62B37D699A6E6EF038E6018E320B85232539F96FFBE6A20F99B8ADB5",
         expected_final => x"DE3453F9EAE92C739A16AFE8A32D40D223EEBAEC010684440C46D33E39473763"),
        -- 5: Genesis block, wire format. Display hash 000000000019d6...8ce26f
        (block_header => x"0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c",
         expected_first => x"af42031e805ff493a07341e2f74ff58149d22ab9ba19f61343e2c86c71c5d66d",
         expected_final => x"6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000"),
        -- 6: Block 125552, wire format. Display hash 00000000000000001e8d...98bd1d
        (block_header => x"0100000081cd02ab7e569e8bcd9317e2fe99f2de44d49ab2b8851ba4a308000000000000e320b6c2fffc8d750423db8b1eb942ae710e951ed797f7affc8892b0f1fc122bc7f5d74df2b9441a42a14695",
         expected_first => x"b9d751533593ac10cdfb7b8e03cad8babc67d8eaeac0a3699b82857dacac9390",
         expected_final => x"1dbd981fe6985776b644b173a4d0385ddc1aa2a829688d1e0000000000000000")
    );

    constant GENESIS_DISPLAY : std_logic_vector(255 downto 0) :=
        x"000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f";
    constant BLOCK_125552_DISPLAY : std_logic_vector(255 downto 0) :=
        x"00000000000000001e8d6829a8a21adc5d38d0a473b144b6765798e61f98bd1d";

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal start        : std_logic := '0';
    signal block_header : std_logic_vector(639 downto 0) := (others => '0');
    signal done         : std_logic;
    signal first_hash   : std_logic_vector(255 downto 0);
    signal hash_out     : std_logic_vector(255 downto 0);
    signal running      : boolean := true;

begin

    dut: entity work.sha256_double
        port map (
            clk          => clk,
            rst          => rst,
            start        => start,
            block_header => block_header,
            done         => done,
            first_hash   => first_hash,
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
            block_header <= TEST_VECTORS(i).block_header;
            pulse_start;
            wait_done(cycles);
            check(done = '1', "vector " & integer'image(i) & " completes");
            check(first_hash = TEST_VECTORS(i).expected_first, "vector " & integer'image(i) & " first hash");
            check(hash_out = TEST_VECTORS(i).expected_final, "vector " & integer'image(i) & " final hash");
            if i = 5 then
                check(reverse_bytes(hash_out) = GENESIS_DISPLAY, "genesis display hash 000000000019d6...");
            elsif i = 6 then
                check(reverse_bytes(hash_out) = BLOCK_125552_DISPLAY, "block 125552 display hash 00000000000000001e8d...");
            end if;
            tick(3);
        end loop;
        report "INFO latency: start to done = " & integer'image(cycles + 1) & " cycles";

        -- 2a. start held high
        block_header <= TEST_VECTORS(5).block_header;
        start <= '1';
        wait_done(cycles);
        tick(10);
        check(done = '1' and hash_out = TEST_VECTORS(5).expected_final, "start held: done stays high, hash correct");
        start <= '0';
        tick(2);
        check(done = '0', "start held: done clears after start drops");

        -- 2b. back-to-back
        block_header <= TEST_VECTORS(2).block_header;
        pulse_start;
        wait_done(cycles);
        block_header <= TEST_VECTORS(6).block_header;
        pulse_start;
        wait_done(cycles);
        check(hash_out = TEST_VECTORS(6).expected_final, "back-to-back: second hash correct");

        -- 2c. one-cycle reset during the second pass, start on the next cycle
        tick(3);
        block_header <= TEST_VECTORS(0).block_header;
        pulse_start;
        tick(180);
        rst <= '1';
        tick;
        rst <= '0';
        block_header <= TEST_VECTORS(5).block_header;
        pulse_start;
        wait_done(cycles);
        check(hash_out = TEST_VECTORS(5).expected_final, "reset mid-hash then immediate start: hash correct");

        -- Summary
        running <= false;
        if errors = 0 then
            report "RESULT tb_sha256_double: PASS (" & integer'image(checks) & " checks)";
            finish;
        else
            report "RESULT tb_sha256_double: FAIL (" & integer'image(errors) & " of " & integer'image(checks) & " checks)" severity failure;
        end if;
        wait;
    end process;

end sim;

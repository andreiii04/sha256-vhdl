-- SHA-256 compression core for one pre-padded 512-bit block (FIPS 180-4).
--
-- Iterative architecture, one operation per clock:
--   IDLE            load W[0..15] from message_in and H0..H7 (standard IV
--                   or h_init for chaining) when start = '1'
--   EXTEND_SCHEDULE compute W[16..63], one word per cycle (48 cycles)
--   PROCESSING      one compression round per cycle (64 cycles)
--   DONE_STATE      hash_out = H + {a..h}, done = '1'; stays here while
--                   start = '1', returns to IDLE when start = '0'
--
-- Handshake: pulse or hold start; done is high while in DONE_STATE.
-- Synchronous, active-high reset.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sha256_core is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        start           : in  std_logic;
        message_in      : in  std_logic_vector(511 downto 0);  -- padded block, word 0 in bits 511..480
        h_init          : in  std_logic_vector(255 downto 0);  -- chaining value, used if use_custom_init = '1'
        use_custom_init : in  std_logic;
        done            : out std_logic;
        hash_out        : out std_logic_vector(255 downto 0)
    );
end sha256_core;

architecture Behavioral of sha256_core is

    function rotr(x : std_logic_vector(31 downto 0); n : integer) return std_logic_vector is
    begin
        return std_logic_vector(shift_right(unsigned(x), n) or shift_left(unsigned(x), 32 - n));
    end function;

    function ch(x, y, z : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return (x and y) xor ((not x) and z);
    end function;

    function maj(x, y, z : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return (x and y) xor (x and z) xor (y and z);
    end function;

    function big_sigma0(x : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return rotr(x, 2) xor rotr(x, 13) xor rotr(x, 22);
    end function;

    function big_sigma1(x : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return rotr(x, 6) xor rotr(x, 11) xor rotr(x, 25);
    end function;

    function small_sigma0(x : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return rotr(x, 7) xor rotr(x, 18) xor std_logic_vector(shift_right(unsigned(x), 3));
    end function;

    function small_sigma1(x : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return rotr(x, 17) xor rotr(x, 19) xor std_logic_vector(shift_right(unsigned(x), 10));
    end function;

    -- Round constants
    type k_array is array(0 to 63) of std_logic_vector(31 downto 0);
    constant K : k_array := (
        x"428a2f98", x"71374491", x"b5c0fbcf", x"e9b5dba5", x"3956c25b", x"59f111f1", x"923f82a4", x"ab1c5ed5",
        x"d807aa98", x"12835b01", x"243185be", x"550c7dc3", x"72be5d74", x"80deb1fe", x"9bdc06a7", x"c19bf174",
        x"e49b69c1", x"efbe4786", x"0fc19dc6", x"240ca1cc", x"2de92c6f", x"4a7484aa", x"5cb0a9dc", x"76f988da",
        x"983e5152", x"a831c66d", x"b00327c8", x"bf597fc7", x"c6e00bf3", x"d5a79147", x"06ca6351", x"14292967",
        x"27b70a85", x"2e1b2138", x"4d2c6dfc", x"53380d13", x"650a7354", x"766a0abb", x"81c2c92e", x"92722c85",
        x"a2bfe8a1", x"a81a664b", x"c24b8b70", x"c76c51a3", x"d192e819", x"d6990624", x"f40e3585", x"106aa070",
        x"19a4c116", x"1e376c08", x"2748774c", x"34b0bcb5", x"391c0cb3", x"4ed8aa4a", x"5b9cca4f", x"682e6ff3",
        x"748f82ee", x"78a5636f", x"84c87814", x"8cc70208", x"90befffa", x"a4506ceb", x"bef9a3f7", x"c67178f2"
    );

    -- Standard initial hash value
    constant H0_INIT : std_logic_vector(31 downto 0) := x"6a09e667";
    constant H1_INIT : std_logic_vector(31 downto 0) := x"bb67ae85";
    constant H2_INIT : std_logic_vector(31 downto 0) := x"3c6ef372";
    constant H3_INIT : std_logic_vector(31 downto 0) := x"a54ff53a";
    constant H4_INIT : std_logic_vector(31 downto 0) := x"510e527f";
    constant H5_INIT : std_logic_vector(31 downto 0) := x"9b05688c";
    constant H6_INIT : std_logic_vector(31 downto 0) := x"1f83d9ab";
    constant H7_INIT : std_logic_vector(31 downto 0) := x"5be0cd19";

    type state_type is (IDLE, EXTEND_SCHEDULE, PROCESSING, DONE_STATE);
    signal state : state_type := IDLE;

    -- Shared by schedule extension (0..48) and rounds (0..63)
    signal round_counter : unsigned(5 downto 0) := (others => '0');

    -- Message schedule W[0..63], fully registered
    type w_array is array(0 to 63) of std_logic_vector(31 downto 0);
    signal w : w_array;

    -- Working variables and chaining value
    signal a, b, c, d, e, f, g, h : std_logic_vector(31 downto 0);
    signal h0, h1, h2, h3, h4, h5, h6, h7 : std_logic_vector(31 downto 0);

begin

    process(clk)
        variable t1, t2 : std_logic_vector(31 downto 0);
        variable final_h0, final_h1, final_h2, final_h3 : std_logic_vector(31 downto 0);
        variable final_h4, final_h5, final_h6, final_h7 : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                round_counter <= (others => '0');
                done <= '0';
                hash_out <= (others => '0');

                for i in 0 to 63 loop
                    w(i) <= (others => '0');
                end loop;

                a <= (others => '0'); b <= (others => '0'); c <= (others => '0'); d <= (others => '0');
                e <= (others => '0'); f <= (others => '0'); g <= (others => '0'); h <= (others => '0');
                h0 <= (others => '0'); h1 <= (others => '0'); h2 <= (others => '0'); h3 <= (others => '0');
                h4 <= (others => '0'); h5 <= (others => '0'); h6 <= (others => '0'); h7 <= (others => '0');

            else
                case state is
                    when IDLE =>
                        done <= '0';
                        if start = '1' then
                            state <= EXTEND_SCHEDULE;
                            round_counter <= (others => '0');

                            if use_custom_init = '1' then
                                h0 <= h_init(255 downto 224);
                                h1 <= h_init(223 downto 192);
                                h2 <= h_init(191 downto 160);
                                h3 <= h_init(159 downto 128);
                                h4 <= h_init(127 downto 96);
                                h5 <= h_init(95 downto 64);
                                h6 <= h_init(63 downto 32);
                                h7 <= h_init(31 downto 0);
                            else
                                h0 <= H0_INIT; h1 <= H1_INIT; h2 <= H2_INIT; h3 <= H3_INIT;
                                h4 <= H4_INIT; h5 <= H5_INIT; h6 <= H6_INIT; h7 <= H7_INIT;
                            end if;

                            w(0)  <= message_in(511 downto 480);
                            w(1)  <= message_in(479 downto 448);
                            w(2)  <= message_in(447 downto 416);
                            w(3)  <= message_in(415 downto 384);
                            w(4)  <= message_in(383 downto 352);
                            w(5)  <= message_in(351 downto 320);
                            w(6)  <= message_in(319 downto 288);
                            w(7)  <= message_in(287 downto 256);
                            w(8)  <= message_in(255 downto 224);
                            w(9)  <= message_in(223 downto 192);
                            w(10) <= message_in(191 downto 160);
                            w(11) <= message_in(159 downto 128);
                            w(12) <= message_in(127 downto 96);
                            w(13) <= message_in(95 downto 64);
                            w(14) <= message_in(63 downto 32);
                            w(15) <= message_in(31 downto 0);
                        end if;

                    when EXTEND_SCHEDULE =>
                        -- W[t] = s1(W[t-2]) + W[t-7] + s0(W[t-15]) + W[t-16], t = round_counter + 16
                        if round_counter < 48 then
                            w(to_integer(round_counter + 16)) <= std_logic_vector(
                                unsigned(small_sigma1(w(to_integer(round_counter + 14)))) +
                                unsigned(w(to_integer(round_counter + 9))) +
                                unsigned(small_sigma0(w(to_integer(round_counter + 1)))) +
                                unsigned(w(to_integer(round_counter)))
                            );
                            round_counter <= round_counter + 1;
                        else
                            state <= PROCESSING;
                            round_counter <= (others => '0');
                            a <= h0; b <= h1; c <= h2; d <= h3;
                            e <= h4; f <= h5; g <= h6; h <= h7;
                        end if;

                    when PROCESSING =>
                        -- Critical path: W[round_counter] 64:1 mux -> T1 adder chain -> a/e
                        t1 := std_logic_vector(
                            unsigned(h) +
                            unsigned(big_sigma1(e)) +
                            unsigned(ch(e, f, g)) +
                            unsigned(K(to_integer(round_counter))) +
                            unsigned(w(to_integer(round_counter)))
                        );
                        t2 := std_logic_vector(unsigned(big_sigma0(a)) + unsigned(maj(a, b, c)));

                        h <= g;
                        g <= f;
                        f <= e;
                        e <= std_logic_vector(unsigned(d) + unsigned(t1));
                        d <= c;
                        c <= b;
                        b <= a;
                        a <= std_logic_vector(unsigned(t1) + unsigned(t2));

                        if round_counter = 63 then
                            state <= DONE_STATE;
                        else
                            round_counter <= round_counter + 1;
                        end if;

                    when DONE_STATE =>
                        done <= '1';
                        final_h0 := std_logic_vector(unsigned(a) + unsigned(h0));
                        final_h1 := std_logic_vector(unsigned(b) + unsigned(h1));
                        final_h2 := std_logic_vector(unsigned(c) + unsigned(h2));
                        final_h3 := std_logic_vector(unsigned(d) + unsigned(h3));
                        final_h4 := std_logic_vector(unsigned(e) + unsigned(h4));
                        final_h5 := std_logic_vector(unsigned(f) + unsigned(h5));
                        final_h6 := std_logic_vector(unsigned(g) + unsigned(h6));
                        final_h7 := std_logic_vector(unsigned(h) + unsigned(h7));

                        hash_out <= final_h0 & final_h1 & final_h2 & final_h3 &
                                    final_h4 & final_h5 & final_h6 & final_h7;
                        if start = '0' then
                            state <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end Behavioral;

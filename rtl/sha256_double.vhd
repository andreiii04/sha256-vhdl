-- Bitcoin double SHA-256 of an 80-byte block header: SHA256(SHA256(header)).
--
-- Three passes through one sha256_core:
--   1. header bytes 0..63                    with the standard IV
--   2. header bytes 64..79 + padding         chained from pass 1
--   3. 32-byte first hash + padding          with the standard IV
--
-- Byte order: block_header is the header exactly as serialized on the
-- wire (byte 0 = first byte of the little-endian version field) in bits
-- 639..632. hash_out is the raw digest; the usual block-hash display
-- string is this digest with its 32 bytes reversed.
--
-- Same start/done handshake as sha256_single.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sha256_double is
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        start       : in  std_logic;
        block_header: in  std_logic_vector(639 downto 0);
        done        : out std_logic;
        first_hash  : out std_logic_vector(255 downto 0);  -- SHA256(header)
        hash_out    : out std_logic_vector(255 downto 0)   -- SHA256(first_hash)
    );
end sha256_double;

architecture Behavioral of sha256_double is

    -- 80 bytes -> two 512-bit blocks: header, 0x80, zeros, length 640
    function pad_bitcoin_header(header : std_logic_vector(639 downto 0))
        return std_logic_vector is
        variable result : std_logic_vector(1023 downto 0) := (others => '0');
        variable bit_length : integer := 640;
    begin
        result(1023 downto 384) := header;
        result(383) := '1';
        result(63 downto 0) := std_logic_vector(to_unsigned(bit_length, 64));
        return result;
    end function;

    -- 32 bytes -> one 512-bit block: hash, 0x80, zeros, length 256
    function pad_sha256_result(hash : std_logic_vector(255 downto 0))
        return std_logic_vector is
        variable result : std_logic_vector(511 downto 0) := (others => '0');
        variable bit_length : integer := 256;
    begin
        result(511 downto 256) := hash;
        result(255) := '1';
        result(63 downto 0) := std_logic_vector(to_unsigned(bit_length, 64));
        return result;
    end function;

    type state_type is (IDLE, HASH1_BLOCK1, WAIT1_BLOCK1, HASH1_BLOCK2, WAIT1_BLOCK2, HASH2, WAIT2, DONE_STATE);
    signal state : state_type := IDLE;

    signal core_start : std_logic := '0';
    signal core_done : std_logic;
    signal core_hash_out : std_logic_vector(255 downto 0);
    signal core_message_in : std_logic_vector(511 downto 0);
    signal core_rst : std_logic := '0';
    signal core_h_init : std_logic_vector(255 downto 0);
    signal core_use_custom_init : std_logic := '0';

    signal first_hash_reg : std_logic_vector(255 downto 0);
    signal intermediate_hash : std_logic_vector(255 downto 0);
    signal padded_header : std_logic_vector(1023 downto 0);

    constant SHA256_INIT : std_logic_vector(255 downto 0) :=
        x"6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19";

begin

    sha256_inst: entity work.sha256_core
        port map (
            clk => clk,
            rst => core_rst,
            start => core_start,
            message_in => core_message_in,
            h_init => core_h_init,
            use_custom_init => core_use_custom_init,
            done => core_done,
            hash_out => core_hash_out
        );

    first_hash <= first_hash_reg;

    -- Between passes the core is reset for one cycle (core_rst). Not strictly
    -- needed, since the core returns to IDLE by itself, but kept as verified.
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                core_start <= '0';
                core_rst <= '1';
                core_use_custom_init <= '0';
                done <= '0';
                first_hash_reg <= (others => '0');
                intermediate_hash <= (others => '0');
                hash_out <= (others => '0');
                core_message_in <= (others => '0');
                core_h_init <= (others => '0');
                padded_header <= (others => '0');
            else
                case state is
                    when IDLE =>
                        done <= '0';
                        core_rst <= '0';
                        if start = '1' then
                            padded_header <= pad_bitcoin_header(block_header);
                            core_message_in <= pad_bitcoin_header(block_header)(1023 downto 512);
                            core_h_init <= SHA256_INIT;
                            core_use_custom_init <= '0';
                            core_start <= '1';
                            state <= HASH1_BLOCK1;
                        end if;

                    when HASH1_BLOCK1 =>
                        core_start <= '0';
                        state <= WAIT1_BLOCK1;

                    when WAIT1_BLOCK1 =>
                        if core_done = '1' then
                            intermediate_hash <= core_hash_out;
                            core_rst <= '1';
                            state <= HASH1_BLOCK2;
                        end if;

                    when HASH1_BLOCK2 =>
                        core_rst <= '0';
                        core_message_in <= padded_header(511 downto 0);
                        core_h_init <= intermediate_hash;
                        core_use_custom_init <= '1';
                        core_start <= '1';
                        state <= WAIT1_BLOCK2;

                    when WAIT1_BLOCK2 =>
                        core_start <= '0';
                        if core_done = '1' then
                            first_hash_reg <= core_hash_out;
                            core_rst <= '1';
                            state <= HASH2;
                        end if;

                    when HASH2 =>
                        core_rst <= '0';
                        core_message_in <= pad_sha256_result(first_hash_reg);
                        core_h_init <= SHA256_INIT;
                        core_use_custom_init <= '0';
                        core_start <= '1';
                        state <= WAIT2;

                    when WAIT2 =>
                        core_start <= '0';
                        if core_done = '1' then
                            hash_out <= core_hash_out;
                            state <= DONE_STATE;
                        end if;

                    when DONE_STATE =>
                        done <= '1';
                        if start = '0' then
                            state <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end Behavioral;

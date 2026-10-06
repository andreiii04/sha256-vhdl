-- SHA-256 of a short byte string (0..55 bytes, i.e. one 512-bit block).
--
-- On start: pads the string (FIPS 180-4: 0x80, zeros, 64-bit bit length),
-- runs sha256_core once and raises done. Same start/done handshake as the
-- core: done stays high while start is held, clears after start drops.
--
-- string_in is left-aligned: byte 0 in bits 439..432.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sha256_single is
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        start       : in  std_logic;
        string_in   : in  std_logic_vector(55*8 - 1 downto 0);
        string_len  : in  integer range 0 to 55;
        padded_block: out std_logic_vector(511 downto 0);  -- for verification
        done        : out std_logic;
        hash_out    : out std_logic_vector(255 downto 0)
    );
end sha256_single;

architecture Behavioral of sha256_single is

    constant MAX_STRING_LEN : integer := 55;
    constant CHAR_WIDTH     : integer := 8;
    constant STRING_WIDTH   : integer := MAX_STRING_LEN * CHAR_WIDTH;

    -- Byte i < str_len is copied, byte str_len becomes 0x80, the rest stay 0.
    -- Written per byte with constant slice bounds so any synthesizer accepts it.
    function pad_message(input_bits : std_logic_vector(STRING_WIDTH - 1 downto 0); str_len : integer) return std_logic_vector is
        variable result : std_logic_vector(511 downto 0) := (others => '0');
    begin
        for i in 0 to MAX_STRING_LEN - 1 loop
            if i < str_len then
                result(511 - i * CHAR_WIDTH downto 504 - i * CHAR_WIDTH) :=
                    input_bits(STRING_WIDTH - 1 - i * CHAR_WIDTH downto STRING_WIDTH - (i + 1) * CHAR_WIDTH);
            end if;
        end loop;

        for i in 0 to MAX_STRING_LEN loop
            if i = str_len then
                result(511 - i * CHAR_WIDTH) := '1';
            end if;
        end loop;

        result(63 downto 0) := std_logic_vector(to_unsigned(str_len * CHAR_WIDTH, 64));

        return result;
    end function;

    type state_type is (IDLE, HASHING, DONE_STATE);
    signal state : state_type := IDLE;

    signal core_start : std_logic := '0';
    signal core_done : std_logic;
    signal padded_msg : std_logic_vector(511 downto 0);

begin

    sha256_inst: entity work.sha256_core
        port map (
            clk => clk,
            rst => rst,
            start => core_start,
            message_in => padded_msg,
            h_init => (others => '0'),
            use_custom_init => '0',
            done => core_done,
            hash_out => hash_out
        );

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE;
                core_start <= '0';
                done <= '0';
                padded_block <= (others => '0');
                padded_msg <= (others => '0');
            else
                case state is
                    when IDLE =>
                        done <= '0';
                        if start = '1' then
                            padded_msg <= pad_message(string_in, string_len);
                            padded_block <= pad_message(string_in, string_len);
                            core_start <= '1';
                            state <= HASHING;
                        end if;

                    when HASHING =>
                        core_start <= '0';
                        if core_done = '1' then
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

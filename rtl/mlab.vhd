LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

LIBRARY altera_mf;
USE altera_mf.altera_mf_components.all;

ENTITY mlab IS
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8
	);
	PORT
	(
		clock   		: in  STD_LOGIC;
		rdaddress 	: in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0);
		wraddress 	: in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0);
		data			: in  STD_LOGIC_VECTOR (data_width-1 DOWNTO 0) := (others => '0');
		wren    		: in  STD_LOGIC := '0';
		q       		: out STD_LOGIC_VECTOR (data_width-1 DOWNTO 0);
		cs      		: in  std_logic := '1'
	);
END ENTITY;

-- NOTE (neptUNO+ port): backing memory replaced with a plain register
-- array - altdpram/MLAB with an unregistered read address doesn't exist
-- on Cyclone IV GX (see rtl/SH_mem.sv's SH_regram for the full
-- explanation). This entity is unused by the neptUNO+ build (no live
-- instantiation was found), fixed anyway to remove any doubt.
ARCHITECTURE SYN OF mlab IS
	signal q0 : std_logic_vector((data_width - 1) downto 0);
	type mem_t is array (0 to (2**addr_width)-1) of std_logic_vector(data_width-1 downto 0);
	signal mem : mem_t;
BEGIN
	q <= q0 when cs = '1' else (others => '1');

	process (clock)
	begin
		if rising_edge(clock) then
			if wren = '1' then
				mem(to_integer(unsigned(wraddress))) <= data;
			end if;
		end if;
	end process;

	q0 <= mem(to_integer(unsigned(rdaddress)));

END SYN;
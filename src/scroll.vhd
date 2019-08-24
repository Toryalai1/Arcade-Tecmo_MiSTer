-- Copyright (c) 2019 Josh Bassett
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types.all;

-- The scroll module handles the scrolling foreground and background layers in
-- the graphics pipeline.
--
-- It consists of of a 32x16 grid of 16x16 tiles.
--
-- Because a scrolling layer is twice the width of the screen, it can never be
-- entirely visible on the screen at once. The horizontal and vertical scroll
-- positions are used to set the position of the visible area.
entity scroll is
  generic (
    RAM_ADDR_WIDTH : natural;
    ROM_ADDR_WIDTH : natural;
    ROM_DATA_WIDTH : natural;
    ROM_INIT_FILE  : string
  );
  port (
    -- clock signals
    clk   : in std_logic;
    cen_6 : in std_logic;

    -- scroll RAM
    ram_cs   : in std_logic;
    ram_addr : in std_logic_vector(RAM_ADDR_WIDTH-1 downto 0);
    ram_din  : in byte_t;
    ram_dout : out byte_t;
    ram_we   : in std_logic;

    -- video signals
    video : in video_t;

    -- scroll position signals
    scroll_pos : in pos_t;

    -- layer data
    data : out byte_t
  );
end scroll;

architecture arch of scroll is
  -- represents the position of a pixel in a 16x16 tile
  type tile_pos_t is record
    x : unsigned(3 downto 0);
    y : unsigned(3 downto 0);
  end record tile_pos_t;

  -- tile RAM (port B)
  signal scroll_ram_addr_b : std_logic_vector(RAM_ADDR_WIDTH-1 downto 0);
  signal scroll_ram_dout_b : byte_t;

  -- tile ROM
  signal tile_rom_addr : std_logic_vector(ROM_ADDR_WIDTH-1 downto 0);
  signal tile_rom_dout : std_logic_vector(ROM_DATA_WIDTH-1 downto 0);

  -- tile signals
  signal tile_data  : std_logic_vector(15 downto 0);
  signal tile_code  : tile_code_t;
  signal tile_color : tile_color_t;
  signal tile_pixel : tile_pixel_t;
  signal tile_row   : tile_row_t;

  -- destination position
  signal dest_pos : pos_t;

  -- aliases to extract the components of the horizontal and vertical position
  alias col      : unsigned(4 downto 0) is dest_pos.x(8 downto 4);
  alias row      : unsigned(3 downto 0) is dest_pos.y(7 downto 4);
  alias offset_x : unsigned(3 downto 0) is dest_pos.x(3 downto 0);
  alias offset_y : unsigned(3 downto 0) is dest_pos.y(3 downto 0);
begin
  -- The tile RAM (1kB) contains the code and colour of each tile in the
  -- tilemap.
  --
  -- Each tile in the tilemap is represented by two bytes in the character RAM,
  -- a high byte and a low byte, which contains the tile colour and code.
  --
  -- It has been implemented as a dual-port RAM because both the CPU and the
  -- graphics pipeline need to access the RAM concurrently. Ports A and B are
  -- identical.
  --
  -- This differs from the original arcade hardware, which only contains
  -- a single-port character RAM. Using a dual-port RAM instead simplifies
  -- things, because we don't need all the additional logic required to
  -- coordinate RAM access.
  scroll_ram : entity work.true_dual_port_ram
  generic map (
    ADDR_WIDTH_A => RAM_ADDR_WIDTH,
    ADDR_WIDTH_B => RAM_ADDR_WIDTH
  )
  port map (
    -- port A (CPU)
    clk_a  => clk,
    cs_a   => ram_cs,
    addr_a => ram_addr,
    din_a  => ram_din,
    dout_a => ram_dout,
    we_a   => ram_we,

    -- port B (GPU)
    clk_b  => clk,
    addr_b => scroll_ram_addr_b,
    dout_b => scroll_ram_dout_b
  );

  -- the tile ROM contains the actual pixel data for the tiles
  tile_rom : entity work.single_port_rom
  generic map (
    ADDR_WIDTH => ROM_ADDR_WIDTH,
    DATA_WIDTH => ROM_DATA_WIDTH,
    INIT_FILE  => ROM_INIT_FILE
  )
  port map (
    clk  => clk,
    addr => tile_rom_addr,
    dout => tile_rom_dout
  );

  -- update position counter
  update_pos_counter : process (clk)
  begin
    if rising_edge(clk) and cen_6 = '1' then
      if video.hsync = '1' then
        -- reset to the horizontal scroll position
        dest_pos.x <= scroll_pos.x;
      else
        dest_pos.x <= dest_pos.x + 1;
      end if;
    end if;
  end process;

  -- Load tile data from the scroll RAM.
  --
  -- While the current tile is being rendered, we need to fetch data for the
  -- next tile ahead, so that it is loaded in time to render it on the screen.
  --
  -- The 16-bit tile data words aren't stored contiguously in RAM, instead they
  -- are split into high and low bytes. The high bytes are stored in the
  -- upper-half of the RAM, while the low bytes are stored in the lower-half.
  tile_data_pipeline : process (clk)
  begin
    if rising_edge(clk) then
      case to_integer(offset_x) is
        when 10 =>
          -- load high byte for the next tile
          scroll_ram_addr_b <= std_logic_vector('1' & row & (col+1));

        when 11 =>
          -- latch high byte
          tile_data(15 downto 8) <= scroll_ram_dout_b;

          -- load low byte for the next tile
          scroll_ram_addr_b <= std_logic_vector('0' & row & (col+1));

        when 12 =>
          -- latch low byte
          tile_data(7 downto 0) <= scroll_ram_dout_b;

        when 13 =>
          -- latch code
          tile_code <= unsigned(tile_data(9 downto 0));

        when 15 =>
          -- latch colour
          tile_color <= tile_data(15 downto 12);

        when others => null;
      end case;
    end if;
  end process;

  -- latch the row data from the tile ROM when rendering the last pixel in
  -- every row
  latch_tile_row : process (clk)
  begin
    if rising_edge(clk) then
      if dest_pos.x(2 downto 0) = 7 then
        tile_row <= tile_rom_dout;
      end if;
    end if;
  end process;

  -- set vertical position
  dest_pos.y(7 downto 0) <= video.pos.y(7 downto 0) + scroll_pos.y(7 downto 0);

  -- Set the tile ROM address.
  --
  -- Each 16x16 tile is made up of four separate 8x8 tiles, stored in
  -- a left-to-right, top-to-bottom order.
  --
  -- This address points to a row of the current 8x8 tile in the tile ROM.
  tile_rom_addr <= std_logic_vector(tile_code & offset_y(3) & (not offset_x(3)) & offset_y(2 downto 0));

  -- decode the pixel from the tile row data
  with to_integer(dest_pos.x(2 downto 0)) select
    tile_pixel <= tile_row(31 downto 28) when 0,
                  tile_row(27 downto 24) when 1,
                  tile_row(23 downto 20) when 2,
                  tile_row(19 downto 16) when 3,
                  tile_row(15 downto 12) when 4,
                  tile_row(11 downto 8)  when 5,
                  tile_row(7 downto 4)   when 6,
                  tile_row(3 downto 0)   when 7,
                  (others => '0')        when others;

  -- set graphics data
  data <= tile_color & tile_pixel;
end architecture arch;

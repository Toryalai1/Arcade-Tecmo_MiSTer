--   __   __     __  __     __         __
--  /\ "-.\ \   /\ \/\ \   /\ \       /\ \
--  \ \ \-.  \  \ \ \_\ \  \ \ \____  \ \ \____
--   \ \_\\"\_\  \ \_____\  \ \_____\  \ \_____\
--    \/_/ \/_/   \/_____/   \/_____/   \/_____/
--   ______     ______       __     ______     ______     ______
--  /\  __ \   /\  == \     /\ \   /\  ___\   /\  ___\   /\__  _\
--  \ \ \/\ \  \ \  __<    _\_\ \  \ \  __\   \ \ \____  \/_/\ \/
--   \ \_____\  \ \_____\ /\_____\  \ \_____\  \ \_____\    \ \_\
--    \/_____/   \/_____/ \/_____/   \/_____/   \/_____/     \/_/
--
-- https://joshbassett.info
-- https://twitter.com/nullobject
-- https://github.com/nullobject
--
-- Copyright (c) 2020 Josh Bassett
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

use work.common.all;
use work.math.all;
use work.types.all;

entity tecmo is
  generic (
    -- clock frequency (in MHz)
    CLK_FREQ : real
  );
  port (
    -- reset
    reset : in std_logic;

    -- clock signals
    clk     : in std_logic;
    cen_6   : buffer std_logic; -- 6MHz
    cen_4   : buffer std_logic; -- 4MHz
    cen_384 : buffer std_logic; -- 384KHz

    -- player controls
    joy_1     : in nibble_t;
    joy_2     : in nibble_t;
    buttons_1 : in nibble_t;
    buttons_2 : in nibble_t;

    -- coin/start flags
    coin_1  : in std_logic;
    coin_2  : in std_logic;
    start_1 : in std_logic;
    start_2 : in std_logic;

    -- DIP switches
    dip_allow_continue : in std_logic;
    dip_bonus_life     : in std_logic_vector(1 downto 0);
    dip_cabinet        : in std_logic;
    dip_difficulty     : in std_logic_vector(1 downto 0);
    dip_lives          : in std_logic_vector(1 downto 0);

    -- SDRAM interface
    sdram_addr  : out unsigned(SDRAM_CTRL_ADDR_WIDTH-1 downto 0);
    sdram_data  : out std_logic_vector(SDRAM_CTRL_DATA_WIDTH-1 downto 0);
    sdram_we    : out std_logic;
    sdram_req   : out std_logic;
    sdram_ack   : in std_logic;
    sdram_valid : in std_logic;
    sdram_q     : in std_logic_vector(SDRAM_CTRL_DATA_WIDTH-1 downto 0);

    -- IOCTL interface
    ioctl_addr     : in unsigned(IOCTL_ADDR_WIDTH-1 downto 0);
    ioctl_data     : in byte_t;
    ioctl_wr       : in std_logic;
    ioctl_download : in std_logic;

    -- current game index
    game_index : in unsigned(3 downto 0);

    -- video control signals
    hsync  : out std_logic;
    vsync  : out std_logic;
    hblank : out std_logic;
    vblank : out std_logic;

    -- RGB signals
    r : out std_logic_vector(3 downto 0);
    g : out std_logic_vector(3 downto 0);
    b : out std_logic_vector(3 downto 0);


    -- audio data
    audio : out audio_t
  );
end tecmo;

architecture arch of tecmo is
  -- the number of banks in program ROM #2
  constant BANKS : natural := 32;

  -- the number of bits in the bank register
  constant BANK_REG_WIDTH : natural := ilog2(BANKS);

  -- the current game configuration
  signal game_config : game_config_t;

  -- coin/start states
  signal coin : nibble_t;

  -- CPU signals
  signal cpu_cen     : std_logic;
  signal cpu_addr    : unsigned(CPU_ADDR_WIDTH-1 downto 0);
  signal cpu_din     : byte_t;
  signal cpu_dout    : byte_t;
  signal cpu_ioreq_n : std_logic;
  signal cpu_mreq_n  : std_logic;
  signal cpu_rd_n    : std_logic;
  signal cpu_wr_n    : std_logic;
  signal cpu_rfsh_n  : std_logic;
  signal cpu_int_n   : std_logic := '1';
  signal cpu_m1_n    : std_logic;

  -- chip select signals
  signal prog_rom_1_cs  : std_logic;
  signal prog_rom_2_cs  : std_logic;
  signal work_ram_cs    : std_logic;
  signal sprite_ram_cs  : std_logic;
  signal char_ram_cs    : std_logic;
  signal fg_ram_cs      : std_logic;
  signal bg_ram_cs      : std_logic;
  signal palette_ram_cs : std_logic;
  signal scroll_cs      : std_logic;
  signal joy_1_cs       : std_logic;
  signal buttons_1_cs   : std_logic;
  signal joy_2_cs       : std_logic;
  signal buttons_2_cs   : std_logic;
  signal coin_cs        : std_logic;
  signal dip_sw_1_cs    : std_logic;
  signal dip_sw_2_cs    : std_logic;
  signal bank_cs        : std_logic;
  signal sound_cs       : std_logic;

  -- sound signals
  signal sound_rom_1_cs : std_logic;
  signal sound_rom_2_cs : std_logic;
  signal sound_rom_1_oe : std_logic;
  signal sound_rom_2_oe : std_logic;

  -- ROM signals
  signal sprite_rom_addr  : unsigned(SPRITE_ROM_ADDR_WIDTH-1 downto 0);
  signal sprite_rom_data  : std_logic_vector(SPRITE_ROM_DATA_WIDTH-1 downto 0);
  signal char_rom_addr    : unsigned(CHAR_ROM_ADDR_WIDTH-1 downto 0);
  signal char_rom_data    : std_logic_vector(CHAR_ROM_DATA_WIDTH-1 downto 0);
  signal fg_rom_addr      : unsigned(FG_ROM_ADDR_WIDTH-1 downto 0);
  signal fg_rom_data      : std_logic_vector(FG_ROM_DATA_WIDTH-1 downto 0);
  signal bg_rom_addr      : unsigned(BG_ROM_ADDR_WIDTH-1 downto 0);
  signal bg_rom_data      : std_logic_vector(BG_ROM_DATA_WIDTH-1 downto 0);
  signal sound_rom_1_addr : unsigned(SOUND_ROM_1_ADDR_WIDTH-1 downto 0);
  signal sound_rom_1_data : std_logic_vector(SOUND_ROM_1_DATA_WIDTH-1 downto 0);
  signal sound_rom_2_addr : unsigned(SOUND_ROM_2_ADDR_WIDTH-1 downto 0);
  signal sound_rom_2_data : std_logic_vector(SOUND_ROM_2_DATA_WIDTH-1 downto 0);

  -- data signals
  signal prog_rom_1_dout : byte_t;
  signal prog_rom_2_dout : byte_t;
  signal work_ram_dout   : byte_t;
  signal gpu_dout        : byte_t;
  signal io_dout         : nibble_t;

  -- registers
  signal fg_scroll_pos_reg : pos_t := (x => (others => '0'), y => (others => '0'));
  signal bg_scroll_pos_reg : pos_t := (x => (others => '0'), y => (others => '0'));
  signal bank_reg          : unsigned(BANK_REG_WIDTH-1 downto 0);

  -- video signals
  signal video : video_t;

  -- control signals
  signal vblank_falling : std_logic;

  -- RGB data
  signal rgb : rgb_t;

  function select_coin (
    index   : natural;
    coin_1  : std_logic;
    coin_2  : std_logic;
    start_1 : std_logic;
    start_2 : std_logic
  ) return nibble_t is
  begin
    case index is
      when 0      => return coin_1 & coin_2 & start_1 & start_2; -- rygar
      when others => return coin_2 & coin_1 & start_2 & start_1; -- gemini/silkworm
    end case;
  end select_coin;
begin
  -- generate a 6MHz clock enable signal
  clock_divider_6 : entity work.clock_divider
  generic map (DIVISOR => natural(CLK_FREQ/6.0))
  port map (clk => clk, cen => cen_6);

  -- generate a 4MHz clock enable signal
  clock_divider_4 : entity work.clock_divider
  generic map (DIVISOR => natural(CLK_FREQ/4.0))
  port map (clk => clk, cen => cen_4);

  -- generate a 384KHz clock enable signal
  clock_divider_384 : entity work.clock_divider
  generic map (DIVISOR => natural(CLK_FREQ/0.384))
  port map (clk => clk, cen => cen_384);

  -- detect falling edges of the VBLANK signal
  vblank_edge_detector : entity work.edge_detector
  generic map (FALLING => true)
  port map (
    clk  => clk,
    data => video.vblank,
    q    => vblank_falling
  );

  -- work RAM
  work_ram : entity work.single_port_ram
  generic map (ADDR_WIDTH => WORK_RAM_ADDR_WIDTH)
  port map (
    clk  => clk,
    cs   => work_ram_cs,
    addr => cpu_addr(WORK_RAM_ADDR_WIDTH-1 downto 0),
    din  => cpu_dout,
    dout => work_ram_dout,
    we   => not cpu_wr_n
  );

  -- ROM controller
  rom_controller : entity work.rom_controller
  port map (
    reset => reset,
    clk   => clk,

    -- program ROM #1 interface
    prog_rom_1_cs   => prog_rom_1_cs and cpu_rfsh_n,
    prog_rom_1_oe   => not cpu_rd_n,
    prog_rom_1_addr => cpu_addr(PROG_ROM_1_ADDR_WIDTH-1 downto 0),
    prog_rom_1_data => prog_rom_1_dout,

    -- program ROM #3 interface
    prog_rom_2_cs   => prog_rom_2_cs and cpu_rfsh_n,
    prog_rom_2_oe   => not cpu_rd_n,
    prog_rom_2_addr => bank_reg & cpu_addr(PROG_ROM_2_ADDR_WIDTH-BANK_REG_WIDTH-1 downto 0),
    prog_rom_2_data => prog_rom_2_dout,

    -- sprite ROM interface
    sprite_rom_addr => sprite_rom_addr,
    sprite_rom_data => sprite_rom_data,

    -- character ROM interface
    char_rom_addr => char_rom_addr,
    char_rom_data => char_rom_data,

    -- foreground ROM interface
    fg_rom_addr => fg_rom_addr,
    fg_rom_data => fg_rom_data,

    -- background ROM interface
    bg_rom_addr => bg_rom_addr,
    bg_rom_data => bg_rom_data,

    -- sound ROM #1 interface
    sound_rom_1_cs   => sound_rom_1_cs,
    sound_rom_1_oe   => sound_rom_1_oe,
    sound_rom_1_addr => sound_rom_1_addr,
    sound_rom_1_data => sound_rom_1_data,

    -- sound ROM #2 interface
    sound_rom_2_cs   => sound_rom_2_cs,
    sound_rom_2_oe   => sound_rom_2_oe,
    sound_rom_2_addr => sound_rom_2_addr,
    sound_rom_2_data => sound_rom_2_data,

    -- IOCTL interface
    ioctl_addr     => ioctl_addr,
    ioctl_data     => ioctl_data,
    ioctl_wr       => ioctl_wr,
    ioctl_download => ioctl_download,

    -- SDRAM interface
    sdram_addr  => sdram_addr,
    sdram_data  => sdram_data,
    sdram_we    => sdram_we,
    sdram_req   => sdram_req,
    sdram_ack   => sdram_ack,
    sdram_valid => sdram_valid,
    sdram_q     => sdram_q
  );

  -- main CPU
  cpu : entity work.T80s
  port map (
    RESET_n     => not reset,
    CLK         => clk,
    CEN         => cpu_cen,
    INT_n       => cpu_int_n,
    M1_n        => cpu_m1_n,
    MREQ_n      => cpu_mreq_n,
    IORQ_n      => cpu_ioreq_n,
    RD_n        => cpu_rd_n,
    WR_n        => cpu_wr_n,
    RFSH_n      => cpu_rfsh_n,
    HALT_n      => open,
    BUSAK_n     => open,
    unsigned(A) => cpu_addr,
    DI          => cpu_din,
    DO          => cpu_dout
  );

  -- graphics subsystem
  gpu : entity work.gpu
  port map (
    -- configuration
    config => game_config.gpu_config,

    -- clock signals
    clk   => clk,
    cen_6 => cen_6,

    -- RAM interface
    ram_addr => cpu_addr,
    ram_din  => cpu_dout,
    ram_dout => gpu_dout,
    ram_we   => not cpu_wr_n,

    -- tile ROM interface
    char_rom_addr   => char_rom_addr,
    char_rom_data   => char_rom_data,
    fg_rom_addr     => fg_rom_addr,
    fg_rom_data     => fg_rom_data,
    bg_rom_addr     => bg_rom_addr,
    bg_rom_data     => bg_rom_data,
    sprite_rom_addr => sprite_rom_addr,
    sprite_rom_data => sprite_rom_data,

    -- chip select signals
    char_ram_cs    => char_ram_cs,
    fg_ram_cs      => fg_ram_cs,
    bg_ram_cs      => bg_ram_cs,
    sprite_ram_cs  => sprite_ram_cs,
    palette_ram_cs => palette_ram_cs,

    -- scroll layer positions
    fg_scroll_pos => fg_scroll_pos_reg,
    bg_scroll_pos => bg_scroll_pos_reg,

    -- video signals
    video => video,
    rgb   => rgb
  );

  -- sound subsystem
  snd : entity work.snd
  generic map (CLK_FREQ => CLK_FREQ)
  port map (
    -- configuration
    snd_map => game_config.snd_map,

    -- reset
    reset => reset,

    -- clock signals
    clk     => clk,
    cen_4   => cen_4,
    cen_384 => cen_384,

    -- CPU interface
    req  => sound_cs and not cpu_wr_n,
    data => cpu_dout,

    -- ROM interface
    sound_rom_1_cs   => sound_rom_1_cs,
    sound_rom_1_oe   => sound_rom_1_oe,
    sound_rom_1_addr => sound_rom_1_addr,
    sound_rom_1_data => sound_rom_1_data,

    sound_rom_2_cs   => sound_rom_2_cs,
    sound_rom_2_oe   => sound_rom_2_oe,
    sound_rom_2_addr => sound_rom_2_addr,
    sound_rom_2_data => sound_rom_2_data,

    -- audio data
    audio => audio
  );

  -- Trigger an interrupt on the falling edge of the VBLANK signal.
  --
  -- Once the interrupt request has been accepted by the CPU, it is
  -- acknowledged by activating the IORQ signal during the M1 cycle. This
  -- disables the interrupt signal, and the cycle starts over.
  irq : process (clk)
  begin
    if rising_edge(clk) then
      if cpu_m1_n = '0' and cpu_ioreq_n = '0' then
        cpu_int_n <= '1';
      elsif vblank_falling = '1' then
        cpu_int_n <= '0';
      end if;
    end if;
  end process;

  -- The bank register selects the current bank for program ROM #2.
  set_bank_register : process (clk)
  begin
    if rising_edge(clk) then
      if bank_cs = '1' and cpu_wr_n = '0' then
        bank_reg <= unsigned(cpu_dout(7 downto 3));
      end if;
    end if;
  end process;

  -- set foreground and background scroll position registers
  set_scroll_pos_registers : process (clk)
  begin
    if rising_edge(clk) then
      if scroll_cs = '1' and cpu_wr_n = '0' then
        case cpu_addr(2 downto 0) is
          when "000" => fg_scroll_pos_reg.x(7 downto 0) <= unsigned(cpu_dout(7 downto 0));
          when "001" => fg_scroll_pos_reg.x(8 downto 8) <= unsigned(cpu_dout(0 downto 0));
          when "010" => fg_scroll_pos_reg.y(7 downto 0) <= unsigned(cpu_dout(7 downto 0));
          when "011" => bg_scroll_pos_reg.x(7 downto 0) <= unsigned(cpu_dout(7 downto 0));
          when "100" => bg_scroll_pos_reg.x(8 downto 8) <= unsigned(cpu_dout(0 downto 0));
          when "101" => bg_scroll_pos_reg.y(7 downto 0) <= unsigned(cpu_dout(7 downto 0));
          when others => null;
        end case;
      end if;
    end if;
  end process;

  -- Set CPU clock enable
  --
  -- Different games run the CPU clock at different frequencies (i.e. 4Mhz or
  -- 6Mhz).
  cpu_cen <= cen_6 when game_config.cpu_freq = 6 else cen_4;

  -- set game config
  game_config <= select_game_config(to_integer(game_index));

  -- set coin/start signal
  coin <= select_coin(to_integer(game_index), coin_1, coin_2, start_1, start_2);

  -- set chip select signals
  prog_rom_1_cs  <= '1' when addr_in_range(cpu_addr, game_config.mem_map.prog_rom_1)  else '0';
  prog_rom_2_cs  <= '1' when addr_in_range(cpu_addr, game_config.mem_map.prog_rom_2)  else '0';
  work_ram_cs    <= '1' when addr_in_range(cpu_addr, game_config.mem_map.work_ram)    else '0';
  char_ram_cs    <= '1' when addr_in_range(cpu_addr, game_config.mem_map.char_ram)    else '0';
  fg_ram_cs      <= '1' when addr_in_range(cpu_addr, game_config.mem_map.fg_ram)      else '0';
  bg_ram_cs      <= '1' when addr_in_range(cpu_addr, game_config.mem_map.bg_ram)      else '0';
  sprite_ram_cs  <= '1' when addr_in_range(cpu_addr, game_config.mem_map.sprite_ram)  else '0';
  palette_ram_cs <= '1' when addr_in_range(cpu_addr, game_config.mem_map.palette_ram) else '0';
  scroll_cs      <= '1' when addr_in_range(cpu_addr, game_config.mem_map.scroll)      else '0';
  sound_cs       <= '1' when addr_in_range(cpu_addr, game_config.mem_map.sound)       else '0';
  bank_cs        <= '1' when addr_in_range(cpu_addr, game_config.mem_map.bank)        else '0';
  joy_1_cs       <= '1' when addr_in_range(cpu_addr, game_config.mem_map.joy_1)       else '0';
  joy_2_cs       <= '1' when addr_in_range(cpu_addr, game_config.mem_map.joy_2)       else '0';
  buttons_1_cs   <= '1' when addr_in_range(cpu_addr, game_config.mem_map.buttons_1)   else '0';
  buttons_2_cs   <= '1' when addr_in_range(cpu_addr, game_config.mem_map.buttons_2)   else '0';
  coin_cs        <= '1' when addr_in_range(cpu_addr, game_config.mem_map.coin)        else '0';
  dip_sw_1_cs    <= '1' when addr_in_range(cpu_addr, game_config.mem_map.dip_sw_1)    else '0';
  dip_sw_2_cs    <= '1' when addr_in_range(cpu_addr, game_config.mem_map.dip_sw_2)    else '0';

  -- mux joystick, coin, and DIP switch data
  io_dout <= joy_1                           when joy_1_cs     = '1' and cpu_rd_n = '0'                       else
             joy_2                           when joy_2_cs     = '1' and cpu_rd_n = '0'                       else
             buttons_1                       when buttons_1_cs = '1' and cpu_rd_n = '0'                       else
             buttons_2                       when buttons_2_cs = '1' and cpu_rd_n = '0'                       else
             coin                            when coin_cs      = '1' and cpu_rd_n = '0'                       else
             "0" & dip_cabinet & dip_lives   when dip_sw_1_cs  = '1' and cpu_rd_n = '0' and cpu_addr(0) = '1' else
             dip_difficulty & dip_bonus_life when dip_sw_2_cs  = '1' and cpu_rd_n = '0' and cpu_addr(0) = '0' else
             dip_allow_continue & "000"      when dip_sw_2_cs  = '1' and cpu_rd_n = '0' and cpu_addr(0) = '1' else
             (others => '0');

  -- mux CPU data input
  cpu_din <= prog_rom_1_dout or
             prog_rom_2_dout or
             work_ram_dout or
             gpu_dout or
             io_dout;

  -- set video signals
  hsync  <= video.hsync;
  vsync  <= video.vsync;
  hblank <= video.hblank;
  vblank <= video.vblank;

  -- set RGB signals
  r <= rgb.r;
  g <= rgb.g;
  b <= rgb.b;
end architecture arch;

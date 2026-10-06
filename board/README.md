# Putting the design on a board

This folder is a **template**. Nothing here has been built or run on
hardware yet. The verified part of the project ends at
`rtl/sha256_uart_top.vhd`, which is vendor- and board-independent.

## What a board needs

| Signal | Direction | Notes |
|---|---|---|
| `clk` | in | any clock; set the `CLK_HZ` generic to its frequency |
| `rst` | in | active high, synchronous to `clk` |
| `uart_rx`, `uart_tx` | in / out | USB-UART bridge, 115200 8N1 by default (`BAUD` generic) |
| `led[3:0]` | out | optional: heartbeat, busy, OK, error |

## Steps

1. **Clock.** Pick a frequency the core can meet. 50 MHz is a safe choice.
   `fpga_top.vhd` shows one way to do it on a Xilinx 7-series board: an
   MMCM from a 100 MHz oscillator. On other vendors, use their PLL, or feed
   the board clock directly if it is slow enough.
2. **Reset.** Synchronize the reset button to the clock, and match its
   polarity. `fpga_top.vhd` holds reset until the clock is stable.
3. **Pins.** Copy `template.xdc` (Vivado) and fill in the pins from your
   board's master constraints file. Other tools use their own pin-file format
   with the same signals.
4. **Build.** Create a project with `rtl/*.vhd` and `board/fpga_top.vhd`,
   with `fpga_top` as the top. Then run synthesis, implementation and the
   bitstream. Check the timing report before loading the bitstream.
5. **Test.** Run `python3 host/sha256_uart.py --port <serial port> selftest`.

Expected size: roughly 12k LUTs and 9k flip-flops (open-source synthesis
estimate), so it fits small FPGAs such as the Artix-7 35T.

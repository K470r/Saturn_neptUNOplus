// ============================================================================
//  PLACEHOLDER - THIS MODULE MUST BE REGENERATED IN QUARTUS BEFORE USE.
//
//  altpll (Cyclone IV GX's PLL primitive) cannot be hand-written: Quartus's
//  MegaWizard / IP Catalog computes the VCO multiply/divide and per-output
//  divide/phase fields for you and there is no toolchain available in the
//  session that produced this scaffold to run that generator. Writing a
//  guessed parameter block here would be worse than an obvious stub: it
//  could compile "successfully" while quietly producing the wrong clock,
//  which is much harder to debug than a build that visibly refuses to lock.
//
//  To replace this file:
//    1. In Quartus, Tools > IP Catalog > Basic Functions > Clocks; PLLs and
//       Resets > PLL > ALTPLL.
//    2. Input:  CLOCK_50, 50 MHz.
//    3. Output c0 (clk_sys): 53.748200 MHz (NTSC/normal-dotclock rate;
//       see docs/NEPTUNOPLUS_PORT.md for the other 3 rates MiSTer's
//       reconfigurable PLL switches between, needed for a later milestone).
//    4. Output c1 (clk_ram): same frequency, phase-advanced for SDRAM
//       setup/hold (match the phase MiSTer's own pll.v uses for its
//       outclk_1 relative to outclk_0, e.g. by inspecting that IP's
//       generated .v in Quartus's "View Report" or regenerating from the
//       same .qsys/.ip source if present).
//    5. Name the variation file "pll_sys" (module name must stay pll_sys)
//       and generate both the .v and .qip, overwriting this file and
//       pll_sys.qip.
// ============================================================================

module pll_sys
(
	input  inclk0,
	output c0,
	output c1,
	output locked
);

// Intentionally non-functional: locked is tied low so a build that forgot
// to regenerate this IP fails obviously (the core stays in reset) instead
// of silently running on the wrong clock.
assign c0     = 1'b0;
assign c1     = 1'b0;
assign locked = 1'b0;

endmodule

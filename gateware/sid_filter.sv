// ----------------------------------------------------------------------------
// This file is part of reDIP SID, a MOS 6581/8580 SID FPGA emulation platform.
// Copyright (C) 2022  Dag Lem <resid@nimrod.no>
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.
//
// You may redistribute and modify this source and make products using it under
// the terms of the CERN-OHL-S v2 (https://ohwr.org/cern_ohl_s_v2.txt).
//
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.
//
// Source location: https://github.com/daglem/reDIP-SID
// ----------------------------------------------------------------------------

`default_nettype none

// Clamp index to [-1023, 1023].
// A simple bit check cannot be used since -1024 must not be included.
function sid::s11_t tanh_x_clamp(sid::s13_t x);
    tanh_x_clamp = (x < -1023) ? -1023 :
                   (x >  1023) ?  1023 :
                   11'(x);
endfunction

// y = tanh(x) is mirrored about y = x.
// We take advantage of this to halve the memory used for the lookup table.
function sid::reg10_t tanh_x_mirror(sid::s11_t x);
    tanh_x_mirror = 10'(x < 0 ? -x : x);
endfunction

function sid::s16_t tanh_y_mirror(logic x_neg, sid::s16_t y);
    tanh_y_mirror = x_neg ? -y : y;
endfunction


module sid_filter #(
    // The 6581 DC offset is approximately -1/18 of the dynamic range of one voice.
    localparam MIXER_DC_6581 = 24'(-(1 << 20)/18),
    localparam MIXER_DC_8580 = 24'sd0
)(
    input  logic           clk,
    input  logic [2:0]     stage,
    input  sid::filter_i_t filter_i,
    output sid::filter_v_t state_o,
    output sid::s24_t      audio_o
);

    sid::reg11_t fc;
    sid::reg11_t fc_6581;
    sid::s16_t   w0_T_lsl17_6581;
    sid::s16_t   w0_T_lsl17_8580;

    // MOS6581 filter cutoff: 200Hz - 24.2kHz (from cutoff curves below)
    // For reference, the datasheet specifies 30Hz - 12kHz.
    //
    // Max w0 = 2*pi*24200 = 152053.
    // In the filter, we must calculate w0*T for a ~1MHz clock.
    // 1.048576/(2^3)*w0 corresponds to 2^17*w0*T, since T =~ 1/1000000,
    // and 2^(3 + 17) = 1048576.
    // This scaled w0*T fits in a signed 16 bit register.
    //
    // As a first approximation, we use filter cutoff curves.
    // Several measurements of such curves can be found at
    // https://bel.fi/alankila/c64-sw/fc-curves/
    //
    // The curves can be approximated quite well by the following formula:
    //
    // fc_curve(x,b,d) = b + 12000*(1 + tanh((fc_dac[x] + d - 1024)/350.0)),
    //
    // - b is the base cutoff frequency, shifting the curve in the y direction
    // - fc_dac[x] is the output from the filter cutoff DAC, adding discontinuities
    // - d is used to offset fc_dac[x], shifting the curve in the x direction
    //
    // Example filter curves:
    //
    // Follin-style: fc_curve(x, 240,  +275)
    // Galway-style: fc_curve(x, 280,  -105)
    // Average     : fc_curve(x, 250,  -500)
    // Strong      : fc_curve(x, 260,  -910)
    // Extreme     : fc_curve(x, 200, -1255)
    //

    sid::s16_t w0_T_lsl17_base = 0;

    // y = tanh(x) is mirrored about y = x.
    // We store only the right half of the function, and use the functions
    // tanh_x and tanh_y for mirroring.
    sid::s16_t w0_T_lsl17_6581_tanh[1024];
    sid::s16_t w0_T_lsl17_6581_y0;
    initial begin
        for (int i = 0; i < 1024; i++) begin
            w0_T_lsl17_6581_tanh[i] = 16'($rtoi(1.048576/8*12000*$tanh(i/350.0) + 0.5));
        end
        // NB! Can't lookup from table here, as this precludes the use of BRAM.
        // w0_T_lsl17_6581_y0 = w0_T_lsl17_6581_tanh[0];
        w0_T_lsl17_6581_y0 = 16'($rtoi(1.048576/8*12000*1 + 0.5));
    end

    // MOS8580 filter cutoff: 0 - 12.5kHz.
    // Max w0 = 2*pi*12500 = 78540
    // We us the same scaling factor for w0*T as above.
    // The maximum value of the scaled w0*T is 1.048576/8*2*pi*12500 = 10294,
    // which is approximately 5 times the maximum fc (2^11 - 1 = 2047),
    // and may be calculated as 5*fc = 4*fc + fc (shift and add).

    // MOS6581 filter cutoff DAC output.
    sid_dac #(
        .BITS(11)
    ) filter_dac (
        .vin  (fc),
        .vout (fc_6581)
    );

    // Filter resonance.
    //
    // MOS6581: 1/Q =~ ~res/8
    // MOS8580: 1/Q =~ 2^((4 - res)/8)
    //
    // The values are multiplied by 256 (1 << 8).
    // The coefficient 256 is dispensed of later by right-shifting 8 times.
    sid::reg9_t _1_Q_lsl8;

    sid::reg9_t _1_Q_8580_lsl8[16];
    initial begin
        for (int res = 0; res < 16; res++) begin
            _1_Q_8580_lsl8[res] = 9'($rtoi(256*$pow(2, (4 - res)/8.0) + 0.5));
        end
    end

    sid::s24_t vi = 0;
    sid::s24_t vd = 0;
    sid::s24_t amix;

    // Hardware 16x16->32 multiply-add:
    // o = c +- (a * b)
    sid::s32_t o;
    sid::s32_t c;
    logic      s;
    sid::s16_t a;
    sid::s16_t b;

    muladd opamp (
        .c (c),
        .s (s),
        .a (a),
        .b (b),
        .o (o)
    );

    // vlp = vlp - w0*vbp
    // vbp = vbp - w0*vhp
    // vhp = 1/Q*vbp - vlp - vi

    sid::s24_t dv;
    sid::s24_t vlp_next;

    sid::reg11_t fc_x;

    always_comb begin
        // Filter cutoff register value.
        fc = { filter_i.regs.fc_hi, filter_i.regs.fc_lo[2:0] };

        // Audio mixer / master volume input.
        // Each voice is 20.5 bits, i.e. the sum of four voices is 22.5 bits.
        // We assume that we never exceed 24 bits.
        // We cannot put this in always_ff since SystemVerilog doesn't support
        // array slices on expressions.
        amix =
            vd +
            (filter_i.regs.mode[0] ? state_o.vlp : 0) +
            (filter_i.regs.mode[1] ? state_o.vbp : 0) +
            (filter_i.regs.mode[2] ? o[23:0] : 0);  // vhp, one cycle early

        // Intermediate results for filter.
        // Shifts -w0*vbp and -w0*vlp right by 17 - 8 = 9.
        dv       = { o[31], o[9 +: 23] };
        vlp_next = filter_i.state.vlp + dv;
    end

    always_ff @(posedge clk) begin
        case (stage)
          1: begin
              // MOS6581: w0 = filter curve
              // 1.048576/8*fc_base is approximated by fc_base >> 3.
              w0_T_lsl17_base <= { 10'b0, filter_i.fc_base[8:3] };
              // We have to register fc_x in order to meet timing.
              fc_x <= tanh_x_clamp(signed'(13'(fc_6581)) + filter_i.fc_offset);

              // MOS8580: w0 = 5*fc = 4*fc + fc
              w0_T_lsl17_8580 <= { 3'b0, fc, 2'b0 } + { 5'b0, fc };

              // MOS6581: 1/Q =~ ~res/8
              // MOS8580: 1/Q =~ 2^((4 - res)/8)
              _1_Q_lsl8 <= (filter_i.model == sid::MOS6581) ?
                          { ~filter_i.regs.res, 5'b0 } :
                          _1_Q_8580_lsl8[filter_i.regs.res];

              // Mux for filter input.
              vi <= ((filter_i.regs.filt[0]) ? filter_i.voice1 : 0) +
                    ((filter_i.regs.filt[1]) ? filter_i.voice2 : 0) +
                    ((filter_i.regs.filt[2]) ? filter_i.voice3 : 0) +
                    ((filter_i.regs.filt[3]) ? filter_i.ext_in : 0);

              // Mux for direct audio.
              // 3 OFF (mode[3]) disconnects voice 3 from the direct audio path.
              // We add in the mixer DC here, to save time in calculation of
              // amix.
              vd <= ((filter_i.model == sid::MOS6581) ?
                     MIXER_DC_6581 :
                     MIXER_DC_8580) +
                    (filter_i.regs.filt[0] ? 0 : filter_i.voice1) +
                    (filter_i.regs.filt[1] ? 0 : filter_i.voice2) +
                    (filter_i.regs.filt[2] |
                     filter_i.regs.mode[3] ? 0 : filter_i.voice3) +
                    (filter_i.regs.filt[3] ? 0 : filter_i.ext_in);
          end
          2: begin
              // Read from BRAM.
              w0_T_lsl17_6581 <= w0_T_lsl17_6581_tanh[tanh_x_mirror(fc_x)];
          end
          3: begin
              // vbp = vbp - w0*vhp
              // We first calculate -w0*vhp
              c <= 0;
              s <= 1'b1;
              a <= (filter_i.model == sid::MOS6581) ?
                   w0_T_lsl17_base + w0_T_lsl17_6581_y0 + tanh_y_mirror(fc_x[10], w0_T_lsl17_6581) :
                   w0_T_lsl17_8580;              // w0*T << 17
              b <= filter_i.state.vhp[8 +: 16];  // vhp  >>  8
          end
          4: begin
              // Result for vbp ready. See calculation of dv above.
              state_o.vbp <= filter_i.state.vbp + dv;

              // vlp = vlp - w0*vbp
              // We first calculate -w0*vbp
              c <= 0;
              s <= 1'b1;
              // a <= a;                            // w0*T << 17
              b <= filter_i.state.vbp[8 +: 16];  // vbp  >>  8
          end
          5: begin
              // Result for vlp ready. See calculation of vlp_next above.
              state_o.vlp <= vlp_next;

              // vhp = 1/Q*vbp - vlp - vi
              // We use a concatenation on -(vlp + vi) to make Verilator happy.
              c <= 32'(signed'({ -(vlp_next + vi) }));
              s <= 1'b0;
              a <= 16'(_1_Q_lsl8);        // 1/Q << 8
              b <= state_o.vbp[8 +: 16];  // vbp >> 8
          end
          6: begin
              // Result for vhp ready.
              state_o.vhp <= o[23:0];

              // aout = vol*amix
              // In the real SID, the signal is inverted first in the mixer
              // op-amp, and then again in the volume control op-amp.
              c <= 0;
              s <= 1'b0;
              a <= { 8'b0, filter_i.regs.vol, 4'b0 };  // vol  << 8
              b <= amix[8 +: 16];                      // amix >> 8
          end
          7: begin
              // Final result for audio output ready.
              // The effective width is 20 bits (4 bit volume * 16 bit amix).
              audio_o <= o[23:0];
          end
        endcase
    end
endmodule
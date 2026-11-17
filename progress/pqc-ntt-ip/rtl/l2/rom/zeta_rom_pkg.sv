// zeta_rom_pkg: constant ROM tables of zeta_rom (L2), one set per ALGO.
//
// GENERATED FILE, do not edit. Generator: rtl/l2/rom/gen_rom_pkg.py
// Source: golden model ROM dumps rtl/l2/rom/rom_{zeta,gamma,k2}_<algo>.hex,
// copied from model/vectors after 'make -C model vectors' (see the generator).
//
// Index order: [algo][address], algo = mlkem_pkg::algo_e value
// (0 BARRETT, 1 MONT12, 2 SHIFTADD, 3 K2RED).
//   ZETA_ROM_TBL [a][i] = zeta_i * S^-1 mod q          (i = zeta index)
//   GAMMA_ROM_TBL[a][i] = gamma_i (S = 1), gamma_i * S^-2 (S != 1) (i = pair)
//   K2_TBL[a]           = S^-2 mod q (1 when S = 1, unused there)
package zeta_rom_pkg;

  localparam int ZR_N_ALGO = 4;
  localparam int ZR_DEPTH  = 128;
  localparam int ZR_W      = 12;

  // zeta ROM, pre-scaled by S^-1
  localparam logic [0:ZR_N_ALGO-1][0:ZR_DEPTH-1][ZR_W-1:0] ZETA_ROM_TBL = {
    12'h001, 12'h6c1, 12'ha14, 12'hcd9, 12'ha52, 12'h276, 12'h769, 12'h350,  // barrett [0..7]
    12'h426, 12'h77f, 12'h0c1, 12'h31d, 12'hae2, 12'hcbc, 12'h239, 12'h6d2,  // barrett [8..15]
    12'h128, 12'h98f, 12'h53b, 12'h5c4, 12'hbe6, 12'h038, 12'h8c0, 12'h535,  // barrett [16..23]
    12'h592, 12'h82e, 12'h217, 12'hb42, 12'h959, 12'hb3f, 12'h7b6, 12'h335,  // barrett [24..31]
    12'h121, 12'h14b, 12'hcb5, 12'h6dc, 12'h4ad, 12'h900, 12'h8e5, 12'h807,  // barrett [32..39]
    12'h28a, 12'h7b9, 12'h9d1, 12'h278, 12'hb31, 12'h021, 12'h528, 12'h77b,  // barrett [40..47]
    12'h90f, 12'h59b, 12'h327, 12'h1c4, 12'h59e, 12'hb34, 12'h5fe, 12'h962,  // barrett [48..55]
    12'ha57, 12'ha39, 12'h5c9, 12'h288, 12'h9aa, 12'hc26, 12'h4cb, 12'h38e,  // barrett [56..63]
    12'h011, 12'hac9, 12'h247, 12'ha59, 12'h665, 12'h2d3, 12'h8f0, 12'h44c,  // barrett [64..71]
    12'h581, 12'ha66, 12'hcd1, 12'h0e9, 12'h2f4, 12'h86c, 12'hbc7, 12'hbea,  // barrett [72..79]
    12'h6a7, 12'h673, 12'hae5, 12'h6fd, 12'h737, 12'h3b8, 12'h5b5, 12'ha7f,  // barrett [80..87]
    12'h3ab, 12'h904, 12'h985, 12'h954, 12'h2dd, 12'h921, 12'h10c, 12'h281,  // barrett [88..95]
    12'h630, 12'h8fa, 12'h7f5, 12'hc94, 12'h177, 12'h9f5, 12'h82a, 12'h66d,  // barrett [96..103]
    12'h427, 12'h13f, 12'had5, 12'h2f5, 12'h833, 12'h231, 12'h9a2, 12'ha22,  // barrett [104..111]
    12'haf4, 12'h444, 12'h193, 12'h402, 12'h477, 12'h866, 12'had7, 12'h376,  // barrett [112..119]
    12'h6ba, 12'h4bc, 12'h752, 12'h405, 12'h83e, 12'hb77, 12'h375, 12'h86a,  // barrett [120..127]
    12'h2ff, 12'h4b1, 12'h59a, 12'ha32, 12'h94e, 12'h1f9, 12'h0e2, 12'h4ed,  // mont12 [0..7]
    12'h8e6, 12'h1c7, 12'h613, 12'h82c, 12'hb9d, 12'h155, 12'h144, 12'h39c,  // mont12 [8..15]
    12'h294, 12'ha3e, 12'h691, 12'h0e8, 12'ha5d, 12'hbbc, 12'h13c, 12'h198,  // mont12 [16..23]
    12'h726, 12'h5f0, 12'h36e, 12'h026, 12'h480, 12'h42a, 12'ha84, 12'h20e,  // mont12 [24..31]
    12'h79d, 12'h369, 12'h65e, 12'h790, 12'ha40, 12'haee, 12'h80f, 12'h620,  // mont12 [32..39]
    12'h9e1, 12'h680, 12'hced, 12'h7f7, 12'h13b, 12'h7d8, 12'h1a8, 12'h2cc,  // mont12 [40..47]
    12'h3db, 12'h81b, 12'hc20, 12'h1d4, 12'h417, 12'ha38, 12'h5a1, 12'h575,  // mont12 [48..55]
    12'hb48, 12'hc6d, 12'h2e2, 12'h3e3, 12'h01c, 12'h70e, 12'h91b, 12'h8a1,  // mont12 [56..63]
    12'hbec, 12'h1bb, 12'h433, 12'h445, 12'h222, 12'h787, 12'h201, 12'h5b7,  // mont12 [64..71]
    12'h83b, 12'h435, 12'hc3c, 12'h8e2, 12'h25e, 12'h9a4, 12'h883, 12'h958,  // mont12 [72..79]
    12'h4d1, 12'h511, 12'h799, 12'h267, 12'h720, 12'h46d, 12'h7fb, 12'h116,  // mont12 [80..87]
    12'h47d, 12'h9e9, 12'h64a, 12'h286, 12'hb7b, 12'h5c5, 12'h9b7, 12'h8ec,  // mont12 [88..95]
    12'hc64, 12'h5f5, 12'h436, 12'hb87, 12'h533, 12'h3c0, 12'h6f5, 12'h018,  // mont12 [96..103]
    12'hbe5, 12'h678, 12'hbad, 12'h55d, 12'h7ea, 12'h34e, 12'h226, 12'h889,  // mont12 [104..111]
    12'h086, 12'h7c1, 12'hb11, 12'h512, 12'h482, 12'h4ab, 12'h4aa, 12'h1be,  // mont12 [112..119]
    12'h9ba, 12'h32d, 12'h9ff, 12'h10e, 12'h1dc, 12'h2e5, 12'hbc0, 12'h3a6,  // mont12 [120..127]
    12'h001, 12'h6c1, 12'ha14, 12'hcd9, 12'ha52, 12'h276, 12'h769, 12'h350,  // shiftadd [0..7]
    12'h426, 12'h77f, 12'h0c1, 12'h31d, 12'hae2, 12'hcbc, 12'h239, 12'h6d2,  // shiftadd [8..15]
    12'h128, 12'h98f, 12'h53b, 12'h5c4, 12'hbe6, 12'h038, 12'h8c0, 12'h535,  // shiftadd [16..23]
    12'h592, 12'h82e, 12'h217, 12'hb42, 12'h959, 12'hb3f, 12'h7b6, 12'h335,  // shiftadd [24..31]
    12'h121, 12'h14b, 12'hcb5, 12'h6dc, 12'h4ad, 12'h900, 12'h8e5, 12'h807,  // shiftadd [32..39]
    12'h28a, 12'h7b9, 12'h9d1, 12'h278, 12'hb31, 12'h021, 12'h528, 12'h77b,  // shiftadd [40..47]
    12'h90f, 12'h59b, 12'h327, 12'h1c4, 12'h59e, 12'hb34, 12'h5fe, 12'h962,  // shiftadd [48..55]
    12'ha57, 12'ha39, 12'h5c9, 12'h288, 12'h9aa, 12'hc26, 12'h4cb, 12'h38e,  // shiftadd [56..63]
    12'h011, 12'hac9, 12'h247, 12'ha59, 12'h665, 12'h2d3, 12'h8f0, 12'h44c,  // shiftadd [64..71]
    12'h581, 12'ha66, 12'hcd1, 12'h0e9, 12'h2f4, 12'h86c, 12'hbc7, 12'hbea,  // shiftadd [72..79]
    12'h6a7, 12'h673, 12'hae5, 12'h6fd, 12'h737, 12'h3b8, 12'h5b5, 12'ha7f,  // shiftadd [80..87]
    12'h3ab, 12'h904, 12'h985, 12'h954, 12'h2dd, 12'h921, 12'h10c, 12'h281,  // shiftadd [88..95]
    12'h630, 12'h8fa, 12'h7f5, 12'hc94, 12'h177, 12'h9f5, 12'h82a, 12'h66d,  // shiftadd [96..103]
    12'h427, 12'h13f, 12'had5, 12'h2f5, 12'h833, 12'h231, 12'h9a2, 12'ha22,  // shiftadd [104..111]
    12'haf4, 12'h444, 12'h193, 12'h402, 12'h477, 12'h866, 12'had7, 12'h376,  // shiftadd [112..119]
    12'h6ba, 12'h4bc, 12'h752, 12'h405, 12'h83e, 12'hb77, 12'h375, 12'h86a,  // shiftadd [120..127]
    12'h8ed, 12'ha0b, 12'hb9a, 12'h714, 12'h5d5, 12'h58e, 12'h11f, 12'h0ca,  // k2red [0..7]
    12'hc56, 12'h26e, 12'h629, 12'h0b6, 12'h3c2, 12'h84f, 12'h73f, 12'h5bc,  // k2red [8..15]
    12'h23d, 12'h7d4, 12'h108, 12'h17f, 12'h9c4, 12'h5b2, 12'h6bf, 12'hc7f,  // k2red [16..23]
    12'ha58, 12'h3f9, 12'h2dc, 12'h260, 12'h6fb, 12'h19b, 12'hc34, 12'h6de,  // k2red [24..31]
    12'h4c7, 12'h28c, 12'had9, 12'h3f7, 12'h7f4, 12'h5d3, 12'hbe7, 12'h6f9,  // k2red [32..39]
    12'h204, 12'hcf9, 12'hbc1, 12'ha67, 12'h6af, 12'h877, 12'h07e, 12'h5bd,  // k2red [40..47]
    12'h9ac, 12'hca7, 12'hbf2, 12'h33e, 12'h06b, 12'h774, 12'hc0a, 12'h94a,  // k2red [48..55]
    12'hb73, 12'h3c1, 12'h71d, 12'ha2c, 12'h1c0, 12'h8d8, 12'h2a5, 12'h806,  // k2red [56..63]
    12'h8b2, 12'h1ae, 12'h22b, 12'h34b, 12'h81e, 12'h367, 12'h60e, 12'h069,  // k2red [64..71]
    12'h1a6, 12'h24b, 12'h0b1, 12'hc16, 12'hbde, 12'hb35, 12'h626, 12'h675,  // k2red [72..79]
    12'hc0b, 12'h30a, 12'h487, 12'hc6e, 12'h9f8, 12'h5cb, 12'haa7, 12'h45f,  // k2red [80..87]
    12'h6cb, 12'h284, 12'h999, 12'h15d, 12'h1a2, 12'h149, 12'hc65, 12'hcb6,  // k2red [88..95]
    12'h331, 12'h449, 12'h25b, 12'h262, 12'h52a, 12'h7fc, 12'h748, 12'h180,  // k2red [96..103]
    12'h842, 12'hc79, 12'h4c2, 12'h7ca, 12'h997, 12'h0dc, 12'h85e, 12'h686,  // k2red [104..111]
    12'h860, 12'h707, 12'h803, 12'h31a, 12'h71b, 12'h9ab, 12'h99b, 12'h1de,  // k2red [112..119]
    12'hc95, 12'hbcd, 12'h3e4, 12'h3df, 12'h3be, 12'h74d, 12'h5f2, 12'h65c  // k2red [120..127]
  };

  // gamma ROM, pre-scaled by S^-2 when S != 1
  localparam logic [0:ZR_N_ALGO-1][0:ZR_DEPTH-1][ZR_W-1:0] GAMMA_ROM_TBL = {
    12'h011, 12'hcf0, 12'hac9, 12'h238, 12'h247, 12'haba, 12'ha59, 12'h2a8,  // barrett [0..7]
    12'h665, 12'h69c, 12'h2d3, 12'ha2e, 12'h8f0, 12'h411, 12'h44c, 12'h8b5,  // barrett [8..15]
    12'h581, 12'h780, 12'ha66, 12'h29b, 12'hcd1, 12'h030, 12'h0e9, 12'hc18,  // barrett [16..23]
    12'h2f4, 12'ha0d, 12'h86c, 12'h495, 12'hbc7, 12'h13a, 12'hbea, 12'h117,  // barrett [24..31]
    12'h6a7, 12'h65a, 12'h673, 12'h68e, 12'hae5, 12'h21c, 12'h6fd, 12'h604,  // barrett [32..39]
    12'h737, 12'h5ca, 12'h3b8, 12'h949, 12'h5b5, 12'h74c, 12'ha7f, 12'h282,  // barrett [40..47]
    12'h3ab, 12'h956, 12'h904, 12'h3fd, 12'h985, 12'h37c, 12'h954, 12'h3ad,  // barrett [48..55]
    12'h2dd, 12'ha24, 12'h921, 12'h3e0, 12'h10c, 12'hbf5, 12'h281, 12'ha80,  // barrett [56..63]
    12'h630, 12'h6d1, 12'h8fa, 12'h407, 12'h7f5, 12'h50c, 12'hc94, 12'h06d,  // barrett [64..71]
    12'h177, 12'hb8a, 12'h9f5, 12'h30c, 12'h82a, 12'h4d7, 12'h66d, 12'h694,  // barrett [72..79]
    12'h427, 12'h8da, 12'h13f, 12'hbc2, 12'had5, 12'h22c, 12'h2f5, 12'ha0c,  // barrett [80..87]
    12'h833, 12'h4ce, 12'h231, 12'had0, 12'h9a2, 12'h35f, 12'ha22, 12'h2df,  // barrett [88..95]
    12'haf4, 12'h20d, 12'h444, 12'h8bd, 12'h193, 12'hb6e, 12'h402, 12'h8ff,  // barrett [96..103]
    12'h477, 12'h88a, 12'h866, 12'h49b, 12'had7, 12'h22a, 12'h376, 12'h98b,  // barrett [104..111]
    12'h6ba, 12'h647, 12'h4bc, 12'h845, 12'h752, 12'h5af, 12'h405, 12'h8fc,  // barrett [112..119]
    12'h83e, 12'h4c3, 12'hb77, 12'h18a, 12'h375, 12'h98c, 12'h86a, 12'h497,  // barrett [120..127]
    12'h255, 12'haac, 12'h0df, 12'hc22, 12'h8d6, 12'h42b, 12'hac0, 12'h241,  // mont12 [0..7]
    12'ha61, 12'h2a0, 12'hcbe, 12'h043, 12'h289, 12'ha78, 12'h0f8, 12'hc09,  // mont12 [8..15]
    12'h5e0, 12'h721, 12'h1d3, 12'hb2e, 12'h7f3, 12'h50e, 12'hc13, 12'h0ee,  // mont12 [16..23]
    12'h817, 12'h4ea, 12'h824, 12'h4dd, 12'h087, 12'hc7a, 12'h181, 12'hb80,  // mont12 [24..31]
    12'h113, 12'hbee, 12'hac5, 12'h23c, 12'h1a7, 12'hb5a, 12'h90c, 12'h3f5,  // mont12 [32..39]
    12'h33c, 12'h9c5, 12'h08e, 12'hc73, 12'h92f, 12'h3d2, 12'h0aa, 12'hc57,  // mont12 [40..47]
    12'h97b, 12'h386, 12'h6cf, 12'h632, 12'hc44, 12'h0bd, 12'hae6, 12'h21b,  // mont12 [48..55]
    12'h1e0, 12'hb21, 12'h3e7, 12'h91a, 12'h00c, 12'hcf5, 12'h306, 12'h9fb,  // mont12 [56..63]
    12'hac2, 12'h23f, 12'h4ac, 12'h855, 12'h4d2, 12'h82f, 12'hbd2, 12'h12f,  // mont12 [64..71]
    12'h89b, 12'h466, 12'h263, 12'ha9e, 12'h471, 12'h890, 12'h6e3, 12'h61e,  // mont12 [72..79]
    12'h75e, 12'h5a3, 12'h70b, 12'h5f6, 12'h8a3, 12'h45e, 12'h467, 12'h89a,  // mont12 [80..87]
    12'ha44, 12'h2bd, 12'hbf0, 12'h111, 12'h95c, 12'h3a5, 12'h580, 12'h781,  // mont12 [88..95]
    12'hb5c, 12'h1a5, 12'h476, 12'h88b, 12'h963, 12'h39e, 12'h0c3, 12'hc3e,  // mont12 [96..103]
    12'hb75, 12'h18c, 12'h442, 12'h8bf, 12'h143, 12'hbbe, 12'h9dc, 12'h325,  // mont12 [104..111]
    12'h909, 12'h3f8, 12'h418, 12'h8e9, 12'h7b4, 12'h54d, 12'h2b4, 12'ha4d,  // mont12 [112..119]
    12'h8b7, 12'h44a, 12'h971, 12'h390, 12'h08b, 12'hc76, 12'h283, 12'ha7e,  // mont12 [120..127]
    12'h011, 12'hcf0, 12'hac9, 12'h238, 12'h247, 12'haba, 12'ha59, 12'h2a8,  // shiftadd [0..7]
    12'h665, 12'h69c, 12'h2d3, 12'ha2e, 12'h8f0, 12'h411, 12'h44c, 12'h8b5,  // shiftadd [8..15]
    12'h581, 12'h780, 12'ha66, 12'h29b, 12'hcd1, 12'h030, 12'h0e9, 12'hc18,  // shiftadd [16..23]
    12'h2f4, 12'ha0d, 12'h86c, 12'h495, 12'hbc7, 12'h13a, 12'hbea, 12'h117,  // shiftadd [24..31]
    12'h6a7, 12'h65a, 12'h673, 12'h68e, 12'hae5, 12'h21c, 12'h6fd, 12'h604,  // shiftadd [32..39]
    12'h737, 12'h5ca, 12'h3b8, 12'h949, 12'h5b5, 12'h74c, 12'ha7f, 12'h282,  // shiftadd [40..47]
    12'h3ab, 12'h956, 12'h904, 12'h3fd, 12'h985, 12'h37c, 12'h954, 12'h3ad,  // shiftadd [48..55]
    12'h2dd, 12'ha24, 12'h921, 12'h3e0, 12'h10c, 12'hbf5, 12'h281, 12'ha80,  // shiftadd [56..63]
    12'h630, 12'h6d1, 12'h8fa, 12'h407, 12'h7f5, 12'h50c, 12'hc94, 12'h06d,  // shiftadd [64..71]
    12'h177, 12'hb8a, 12'h9f5, 12'h30c, 12'h82a, 12'h4d7, 12'h66d, 12'h694,  // shiftadd [72..79]
    12'h427, 12'h8da, 12'h13f, 12'hbc2, 12'had5, 12'h22c, 12'h2f5, 12'ha0c,  // shiftadd [80..87]
    12'h833, 12'h4ce, 12'h231, 12'had0, 12'h9a2, 12'h35f, 12'ha22, 12'h2df,  // shiftadd [88..95]
    12'haf4, 12'h20d, 12'h444, 12'h8bd, 12'h193, 12'hb6e, 12'h402, 12'h8ff,  // shiftadd [96..103]
    12'h477, 12'h88a, 12'h866, 12'h49b, 12'had7, 12'h22a, 12'h376, 12'h98b,  // shiftadd [104..111]
    12'h6ba, 12'h647, 12'h4bc, 12'h845, 12'h752, 12'h5af, 12'h405, 12'h8fc,  // shiftadd [112..119]
    12'h83e, 12'h4c3, 12'hb77, 12'h18a, 12'h375, 12'h98c, 12'h86a, 12'h497,  // shiftadd [120..127]
    12'hbd3, 12'h12e, 12'h1ef, 12'hb12, 12'hc53, 12'h0ae, 12'h82d, 12'h4d4,  // k2red [0..7]
    12'h434, 12'h8cd, 12'hb06, 12'h1fb, 12'hbcf, 12'h132, 12'h0ed, 12'hc14,  // k2red [8..15]
    12'h88d, 12'h474, 12'hbdd, 12'h124, 12'h664, 12'h69d, 12'h913, 12'h3ee,  // k2red [16..23]
    12'h361, 12'h9a0, 12'h360, 12'h9a1, 12'h4f6, 12'h80b, 12'h7e3, 12'h51e,  // k2red [24..31]
    12'h1eb, 12'hb16, 12'h02c, 12'hcd5, 12'h6e0, 12'h621, 12'h14e, 12'hbb3,  // k2red [32..39]
    12'h8c1, 12'h440, 12'hbf6, 12'h10b, 12'ha4c, 12'h2b5, 12'h0f3, 12'hc0e,  // k2red [40..47]
    12'h846, 12'h4bb, 12'h07a, 12'hc87, 12'h60f, 12'h6f2, 12'h72a, 12'h5d7,  // k2red [48..55]
    12'hbdc, 12'h125, 12'hab4, 12'h24d, 12'hc00, 12'h101, 12'h6c5, 12'h63c,  // k2red [56..63]
    12'ha2d, 12'h2d4, 12'hca5, 12'h05c, 12'hba2, 12'h15f, 12'h918, 12'h3e9,  // k2red [64..71]
    12'h557, 12'h7aa, 12'hcd2, 12'h02f, 12'h5a9, 12'h758, 12'h779, 12'h588,  // k2red [72..79]
    12'h06f, 12'hc92, 12'h876, 12'h48b, 12'h056, 12'hcab, 12'h8aa, 12'h457,  // k2red [80..87]
    12'h136, 12'hbcb, 12'h015, 12'hcec, 12'h348, 12'h9b9, 12'h394, 12'h96d,  // k2red [88..95]
    12'h821, 12'h4e0, 12'haa9, 12'h258, 12'ha48, 12'h2b9, 12'hcf2, 12'h00f,  // k2red [96..103]
    12'h71f, 12'h5e2, 12'haad, 12'h254, 12'hae8, 12'h219, 12'h13e, 12'hbc3,  // k2red [104..111]
    12'hb4f, 12'h1b2, 12'h7b0, 12'h551, 12'h869, 12'h498, 12'h2cb, 12'ha36,  // k2red [112..119]
    12'h755, 12'h5ac, 12'hb47, 12'h1ba, 12'h8f6, 12'h40b, 12'h5cf, 12'h732  // k2red [120..127]
  };

  // K2 = S^-2 mod q
  localparam logic [0:ZR_N_ALGO-1][ZR_W-1:0] K2_TBL = {
    12'h001, 12'h951, 12'h001, 12'h549  // barrett mont12 shiftadd k2red
  };

endpackage

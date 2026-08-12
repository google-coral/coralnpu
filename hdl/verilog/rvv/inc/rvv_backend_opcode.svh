`ifndef HDL_VERILOG_RVV_OPCODE_SVH
`define HDL_VERILOG_RVV_OPCODE_SVH

// funct3
  parameter  OPIVV=3'b000;      // vs2,      vs1, vd.
  parameter  OPFVV=3'b001;      // vs2,      vs1, vd/rd. float, not support
  parameter  OPMVV=3'b010;      // vs2,      vs1, vd/rd.
  parameter  OPIVI=3'b011;      // vs2, imm[4:0], vd.
  parameter  OPIVX=3'b100;      // vs2,      rs1, vd.
  parameter  OPFVF=3'b101;      // vs2,      rs1, vd. float, not support
  parameter  OPMVX=3'b110;      // vs2,      rs1, vd/rd.
  parameter  OPCFG=3'b111;      // vset* instructions        

// funct6
  // OPI* instructions
  parameter VADD            =   6'b000_000;
  parameter VSUB            =   6'b000_010;
  parameter VRSUB           =   6'b000_011;
  parameter VMINU           =   6'b000_100;
  parameter VMIN            =   6'b000_101;
  parameter VMAXU           =   6'b000_110;
  parameter VMAX            =   6'b000_111;
  parameter VAND            =   6'b001_001;
  parameter VOR             =   6'b001_010;
  parameter VXOR            =   6'b001_011;
  parameter VRGATHER        =   6'b001_100;
  parameter VSLIDEUP_RGATHEREI16    =   6'b001_110;
  parameter VSLIDEDOWN      =   6'b001_111;
  parameter VADC            =   6'b010_000;
  parameter VMADC           =   6'b010_001;
  parameter VSBC            =   6'b010_010;
  parameter VMSBC           =   6'b010_011;
  parameter VMERGE_VMV      =   6'b010_111;     // it could be vmerge or vmv, based on vm field
  parameter VMSEQ           =   6'b011_000;
  parameter VMSNE           =   6'b011_001;
  parameter VMSLTU          =   6'b011_010;
  parameter VMSLT           =   6'b011_011;
  parameter VMSLEU          =   6'b011_100;
  parameter VMSLE           =   6'b011_101;
  parameter VMSGTU          =   6'b011_110;
  parameter VMSGT           =   6'b011_111;
  parameter VSADDU          =   6'b100_000;
  parameter VSADD           =   6'b100_001;
  parameter VSSUBU          =   6'b100_010;
  parameter VSSUB           =   6'b100_011;
  parameter VSLL            =   6'b100_101;
  parameter VSMUL_VMVNRR    =   6'b100_111;     // it could be vsmul or vmv<nr>r, based on vm field
  parameter VSRL            =   6'b101_000;
  parameter VSRA            =   6'b101_001;
  parameter VSSRL           =   6'b101_010;
  parameter VSSRA           =   6'b101_011;
  parameter VNSRL           =   6'b101_100;
  parameter VNSRA           =   6'b101_101;
  parameter VNCLIPU         =   6'b101_110;
  parameter VNCLIP          =   6'b101_111;
  parameter VWREDSUMU       =   6'b110_000;
  parameter VWREDSUM        =   6'b110_001;   

  // OPM* instructions
  parameter VREDSUM         =   6'b000_000;
  parameter VREDAND         =   6'b000_001;
  parameter VREDOR          =   6'b000_010;
  parameter VREDXOR         =   6'b000_011;
  parameter VREDMINU        =   6'b000_100;
  parameter VREDMIN         =   6'b000_101;
  parameter VREDMAXU        =   6'b000_110;
  parameter VREDMAX         =   6'b000_111;
  parameter VAADDU          =   6'b001_000;
  parameter VAADD           =   6'b001_001;
  parameter VASUBU          =   6'b001_010;
  parameter VASUB           =   6'b001_011;
  parameter VSLIDE1UP       =   6'b001_110;
  parameter VSLIDE1DOWN     =   6'b001_111;
  parameter VWRXUNARY0      =   6'b010_000;     
  parameter VXUNARY0        =   6'b010_010;     
  parameter VMUNARY0        =   6'b010_100;     
  parameter VCOMPRESS_VTMVTV =  6'b010_111;
  parameter VMANDN          =   6'b011_000;
  parameter VMAND           =   6'b011_001;
  parameter VMOR            =   6'b011_010;
  parameter VMXOR           =   6'b011_011;
  parameter VMORN           =   6'b011_100;
  parameter VMNAND          =   6'b011_101;
  parameter VMNOR           =   6'b011_110;
  parameter VMXNOR          =   6'b011_111;
  parameter VDIVU           =   6'b100_000;
  parameter VDIV            =   6'b100_001;
  parameter VREMU           =   6'b100_010;
  parameter VREM            =   6'b100_011;
  parameter VMULHU          =   6'b100_100;
  parameter VMUL            =   6'b100_101;
  parameter VMULHSU         =   6'b100_110;
  parameter VMULH           =   6'b100_111;
  parameter VMADD           =   6'b101_001;
  parameter VNMSUB          =   6'b101_011;
  parameter VMACC           =   6'b101_101;
  parameter VNMSAC          =   6'b101_111;
  parameter VWADDU          =   6'b110_000;
  parameter VWADD           =   6'b110_001;
  parameter VWSUBU          =   6'b110_010;
  parameter VWSUB           =   6'b110_011;
  parameter VWADDU_W        =   6'b110_100;
  parameter VWADD_W         =   6'b110_101;
  parameter VWSUBU_W        =   6'b110_110;
  parameter VWSUB_W         =   6'b110_111;
  parameter VWMULU          =   6'b111_000;
  parameter VWMULSU         =   6'b111_010;
  parameter VWMUL           =   6'b111_011;
  parameter VWMACCU         =   6'b111_100;
  parameter VWMACC          =   6'b111_101;
  parameter VWMACCUS        =   6'b111_110;
  parameter VWMACCSU        =   6'b111_111;  

// vwxunary0 and vrxunary0, the uop could be vcpop.m, vfirst.m and vmv. They can be distinguished by vs1 field(inst_encoding[19:15]).
  parameter VMV_X_S         =   5'b00000;
  parameter VCPOP           =   5'b10000;
  parameter VFIRST          =   5'b10001;
  parameter VMV_S_X         =   5'b00000;  // vs2 field

// vxunary0, the uop could be vzext.vf2, vzext.vf4, vsext.vf2, vsext.vf4. They can be distinguished by vs1 field(inst_encoding[19:15]).
  parameter VZEXT_VF4       =   5'b00100;
  parameter VSEXT_VF4       =   5'b00101;
  parameter VZEXT_VF2       =   5'b00110;
  parameter VSEXT_VF2       =   5'b00111;

// vmunary0, the uop could be vmsbf, vmsof, vmsif, viota, vid. They can be distinguished by vs1 field(inst_encoding[19:15]).
  parameter VMSBF           =   5'b00001;
  parameter VMSOF           =   5'b00010;
  parameter VMSIF           =   5'b00011;
  parameter VIOTA           =   5'b10000;
  parameter VID             =   5'b10001;

`ifdef ZVE32F_ON
  // OPF* instructions
  parameter VFADD           =   6'b000_000;
  parameter VFSUB           =   6'b000_010;
  parameter VFRSUB          =   6'b100_111;
  parameter VFMUL           =   6'b100_100;
  parameter VFDIV           =   6'b100_000;
  parameter VFRDIV          =   6'b100_001;
  parameter VFMACC          =   6'b101_100;
  parameter VFNMACC         =   6'b101_101;
  parameter VFMSAC          =   6'b101_110;
  parameter VFNMSAC         =   6'b101_111;
  parameter VFMADD          =   6'b101_000;
  parameter VFNMADD         =   6'b101_001;
  parameter VFMSUB          =   6'b101_010;
  parameter VFNMSUB         =   6'b101_011;
  parameter VFUNARY1        =   6'b010_011;
  parameter VFMIN           =   6'b000_100;
  parameter VFMAX           =   6'b000_110;
  parameter VFSGNJ          =   6'b001_000;
  parameter VFSGNJN         =   6'b001_001;
  parameter VFSGNJX         =   6'b001_010;
  parameter VMFEQ           =   6'b011_000;
  parameter VMFNE           =   6'b011_100;
  parameter VMFLT           =   6'b011_011;
  parameter VMFLE           =   6'b011_001;
  parameter VMFGT           =   6'b011_101;
  parameter VMFGE           =   6'b011_111;
  parameter VFMERGE_VFMV    =   6'b010_111;     // it could be vfmerge or vfmv, based on vm field
  parameter VFUNARY0        =   6'b010_010;
  parameter VFREDOSUM       =   6'b000_011;
  parameter VFREDUSUM       =   6'b000_001;
  parameter VFREDMAX        =   6'b000_111;
  parameter VFREDMIN        =   6'b000_101;
  parameter VWRFUNARY0      =   6'b010_000;
  parameter VFSLIDE1UP      =   6'b001_110;
  parameter VFSLIDE1DOWN    =   6'b001_111;

  // vfunary0. They can be distinguished by vs1 field(inst_encoding[19:15]).
  parameter VFCVT_XUFV      =   5'b00000;
  parameter VFCVT_XFV       =   5'b00001;
  parameter VFCVT_RTZXUFV   =   5'b00110;
  parameter VFCVT_RTZXFV    =   5'b00111;
  parameter VFCVT_FXUV      =   5'b00010;
  parameter VFCVT_FXV       =   5'b00011;
  parameter VFWCVTFXU       =   5'b01010;
  parameter VFWCVTFX        =   5'b01011;
  parameter VFNCVTXUF       =   5'b10000;
  parameter VFNCVTXF        =   5'b10001;
  parameter VFNCVTRTZXUF    =   5'b10110;
  parameter VFNCVTRTZXF     =   5'b10111;
  
  // vfunary1. They can be distinguished by vs1 field(inst_encoding[19:15]).
  parameter VFSQRT          =   5'b00000;
  parameter VFRSQRT7        =   5'b00100;
  parameter VFREC7          =   5'b00101;
  parameter VFCLASS         =   5'b10000;
  
  // vwfunary0 and vrfunary0
  parameter VFMV_F_S        =   5'b00000;
  parameter VFMV_S_F        =   5'b00000;  // vs2 field

  `ifdef ZVFBFWMA_ON
  // OPF* instructions
  parameter VFWMACCBF16     =   6'b111_011; 

  // vfunary0. They can be distinguished by vs1 field(inst_encoding[19:15]).
  parameter VFNCVTBF16      =   5'b11101;
  parameter VFWCVTBF16      =   5'b01101;
  `endif
`endif

// parameter for lsu decoding
  parameter  UNIT_STRIDE       = 3'b000;
  parameter  UNORDERED_INDEX   = 3'b001;
  parameter  CONSTANT_STRIDE   = 3'b010;
  parameter  ORDERED_INDEX     = 3'b011;
  parameter  TILE_LDST         = 3'b100;

  parameter  US_REGULAR        = 5'b00000;
  parameter  US_WHOLE_REGISTER = 5'b01000;
  parameter  US_MASK           = 5'b01011;
  parameter  US_FAULT_FIRST    = 5'b10000;

// Number of REG
  parameter NREG1 = 3'b000;  
  parameter NREG2 = 3'b001;
  parameter NREG4 = 3'b011;
  parameter NREG8 = 3'b111;

// Number of FIELD
  parameter NF1 = 3'b000;  
  parameter NF2 = 3'b001;
  parameter NF3 = 3'b010;
  parameter NF4 = 3'b011;
  parameter NF5 = 3'b100;
  parameter NF6 = 3'b101;
  parameter NF7 = 3'b110;
  parameter NF8 = 3'b111;

// ZVT
`ifdef ZVT_ON
  parameter VTXMMXTVV = 6'b111_100; 
  // vwxunary0 and vrxunary0
  parameter VTMVVT    = 5'b11111;
  parameter VTZERO    = 5'b11110;
`endif // ZVT_ON

`endif // HDL_VERILOG_RVV_OPCODE_SVH

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_DEFINE_SVH
`define HDL_VERILOG_RVV_DESIGN_RVV_DEFINE_SVH

// number of scalar core issue lane
`define ISSUE_LANE              4

// multi-issue and multi-read-ports of VRF
`ifdef DISPATCH3
  // the max number of instructions are decoded per cycle in DE stage
  `define NUM_DE_INST           3'd2
  // the max number of uops are written to Uops Queue per cycle in DE stage
  `define NUM_DE_UOP            6
  // the max number of uops are dispated per cycle in DP stage.
  `define NUM_DP_UOP            3
  // the number of read ports for VRF
  `define NUM_DP_VRF            6

  // the depth of queue/station/buffer
  `define CQ_DEPTH              8
  `define LCQ_DEPTH             8
  `define UQ_DEPTH              16
  `define ALU_RS_DEPTH          8
  `define PMTRDT_RS_DEPTH       4
  `define MUL_RS_DEPTH          8
  `define DIV_RS_DEPTH          4
  `define FALU_RS_DEPTH         8
  `define FRDT_RS_DEPTH         4
  `define LSU_RS_DEPTH          4
  `define LSUMAP_DEPTH          8
  `define ROB_DEPTH             8

`else  // DISPATCH2
  // the max number of instructions are decoded per cycle in DE stage
  `define NUM_DE_INST           3'd2
  // the max number of uops are written to Uops Queue per cycle in DE stage
  `define NUM_DE_UOP            4
  // the max number of uops are dispated per cycle in DP stage
  `define NUM_DP_UOP            2
  // the number of read ports for VRF
  `define NUM_DP_VRF            4

  // the depth of queue/station/buffer
  `define CQ_DEPTH              8
  `define LCQ_DEPTH             8
  `define UQ_DEPTH              16
  `define ALU_RS_DEPTH          4
  `define PMTRDT_RS_DEPTH       8
  `define MUL_RS_DEPTH          4
  `define DIV_RS_DEPTH          4
  `define FALU_RS_DEPTH         4
  `define FRDT_RS_DEPTH         4
  `define LSU_RS_DEPTH          4
  `define LSUMAP_DEPTH          8
  `define ROB_DEPTH             8
`endif

// VRF REG depth
`define NUM_VRF                 32

// Uops Queue data width
`define UQ_WIDTH                $bits(UOP_QUEUE_t)

// the max number of processor unit in EX stage
`define NUM_LSU                 2
`define NUM_ALU                 2
`define NUM_MUL                 2
`define NUM_PMTRDT              1
`define NUM_DIV                 1

`ifdef ZVE32F_ON
  `define NUM_FALU              2
  `define NUM_FRDT              1
  `define NUM_FDIV              1
  `define NUM_FSUB              4
`else
  `define NUM_FALU              0
  `define NUM_FRDT              0
  `define NUM_FDIV              0
  `define NUM_FSUB              0
`endif

`ifdef ZVT_ON
  `define NUM_VME               1
`else
  `define NUM_VME               0
`endif

`define NUM_ARI               (`NUM_ALU+`NUM_PMTRDT+`NUM_MUL+`NUM_DIV+`NUM_FALU+`NUM_VME)
`define NUM_PU                (`NUM_ARI+`NUM_LSU)

`ifdef ARBITER_ON
`define NUM_SMPORT              4
`else
`define NUM_SMPORT              (`NUM_PU)
`endif

`define ROB_DEPTH_WIDTH         $clog2(`ROB_DEPTH)
`define NUM_RT_UOP              4
`define PC_WIDTH                32
`define XLEN                    32
`define FLEN                    32
`define BYTE_WIDTH              8
`define HWORD_WIDTH             16
`define WORD_WIDTH              32
`define EMUL_MAX                8

`ifdef ZVE32F_ON
  `define LAST_UOP_VLD        1
  `ifdef TB_SUPPORT
    `define FP_RDT_TAG_WIDTH  (`LAST_UOP_VLD+`PC_WIDTH+`ROB_DEPTH_WIDTH)
  `else
    `define FP_RDT_TAG_WIDTH  (`LAST_UOP_VLD+`ROB_DEPTH_WIDTH)
  `endif
`else
  // Define FP variables even if not used
  // TODO(derekjchow): Remove FP modules from chisel build once float is
  // configurable.
  `define FP_RDT_TAG_WIDTH    0
`endif

// ALU instruction will be split 8 uops at most
`define UOP_NUM_ALU             8
`define UOP_INDEX_WIDTH_ALU     $clog2(`UOP_NUM_ALU)

// LSU instruction will be split to EMUL_max=32 uops at most
`define UOP_NUM_LSU             32
`define UOP_INDEX_WIDTH_LSU     $clog2(`UOP_NUM_LSU)

// max(`UOP_INDEX_WIDTH_ALU,`UOP_INDEX_WIDTH_LSU)
`define UOP_INDEX_WIDTH         5

// Vector 
`ifdef VLEN_128
`define VLEN                    128
`endif
`ifdef VLEN_256
`define VLEN                    256
`endif
`ifdef VLEN_512
`define VLEN                    512
`endif
`ifdef VLEN_1024
`define VLEN                    1024
`endif

`define VLENB                   (`VLEN/`BYTE_WIDTH)
`define VLENH                   (`VLEN/`HWORD_WIDTH)
`define VLENW                   (`VLEN/`WORD_WIDTH)
// VLMAX = VLEN*LMUL/SEW
// vstart < VLMAX_max and vl <= VLMAX_max, VLMAX_max=VLEN*LMUL_max(8)/SEW_min(8)=VLEN
`define VLMAX_MAX               `VLEN
`define VSTART_WIDTH            $clog2(`VLEN)
`define VL_WIDTH                $clog2(`VLEN)+1
`define VTYPE_VILL_WIDTH        1
`define VTYPE_VMA_WIDTH         1
`define VTYPE_VTA_WIDTH         1
`define VTYPE_VSEW_WIDTH        3
`define VTYPE_VLMUL_WIDTH       3
`define VCSR_VXRM_WIDTH         2
`define VCSR_VXSAT_WIDTH        1

// Instruction encoding
`define FUNCT6_WIDTH            6
`define NFIELD_WIDTH            3
`define VM_WIDTH                1
`define REGFILE_INDEX_WIDTH     5
`define UMOP_WIDTH              5
`define NREG_WIDTH              3
`define IMM_WIDTH               5
`define FUNCT3_WIDTH            3
`define OPCODE_WIDTH            7

// V0 mask regsiter index
`define V0_INDEX                5'b00000

// ZVT
`ifdef ZVT_ON
  `define ZVT_RS_DEPTH        (`ZVT_LMUL*2)
  
  `define NUM_ACC             16
  // 16 byte each subtile
  `define SUBTILE_SIZE        16
  `define NUM_BLK             4
  
  `define TE                  (`VLEN/8)

  `ifdef ZVT_MAXCOMPUTING
  `define COMPRATIO           1/4
  `else       
  `define COMPRATIO           4/`TE
  `endif 

  `ifdef ZVT_MAXCOMPUTING
  `define PROCESS_DELAY       4
  `define NUM_PE              (`TE*`TE/4)
  `else
  `define PROCESS_DELAY       (`TE/4)
  `define NUM_PE              (4*`TE)
  `endif
  `define ZVT_LMUL            (`WORD_WIDTH*`TE/`VLEN)
  // The quantity of subtile for each acc
  `define NUM_SUBTILE         (`TE*`TE/`SUBTILE_SIZE)
  // The quantity of subtile ports for each block
  `ifdef ZVT_MAXCOMPUTING
  `define NUM_BLKPORT         (((`TE + 15) / 16) * `TE/4)
  `else
  `define NUM_BLKPORT         (`TE/4)
  `endif
`endif // ZVT_ON

`endif // HDL_VERILOG_RVV_DESIGN_RVV_DEFINE_SVH

`ifndef HDL_VERILOG_RVV_INC_FALU_SVH
`define HDL_VERILOG_RVV_INC_FALU_SVH

//FALU subunit struct, 
typedef struct packed {   
  logic   [3:0]                       ftype;
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  FUNCT6_u                            uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3;
  logic                               is_fcmp;
  RVFRM                               frm;
  logic   [`REGFILE_INDEX_WIDTH-1:0]  vs1;              
  logic   [`WORD_WIDTH-1:0]           src1;           
  logic                               src1_valid; 
  logic   [`WORD_WIDTH-1:0]           src2;	        
  logic                               src2_valid; 
  EEW_e                               src2_eew; 
  logic   [`WORD_WIDTH-1:0]           src3;	
  logic                               src3_valid; 
  logic                               last_uop_valid;
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]  uop_index;      
} FMA_SUB_t;

// Tag struct
typedef struct packed {
`ifdef TB_SUPPORT
  logic     [`PC_WIDTH-1:0]           uop_pc;
`endif
  logic     [`ROB_DEPTH_WIDTH-1:0]    rob_entry;
} TAG_t;

typedef struct packed {
  TAG_t                               com_tag;
  logic                               is_fcmp;
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]  uop_index;      
  logic                               last_uop_valid;     
} FCMP_TAG_t;

typedef struct packed {
  logic   [`VSTART_WIDTH-1:0]         vstart;
  logic   [`VL_WIDTH-1:0]             vl;       
  logic                               vm; 
  logic   [`VLENW*`EMUL_MAX-1:0]      v0;
  logic   [`VLEN-1:0]                 vd;
} FCMP_INFO_t;

typedef struct packed {
  TAG_t                               com_tag;
  EEW_e                               eew_vd;
  logic                               uop_index;      
} FCVT_TAG_t;

// SUB stand for sub-unit in FMA
// send SUB result to ROB
typedef struct packed {
  logic     [`WORD_WIDTH-1:0]         w_data;             
  RVFEXP_t  [3:0]                     fpexp;
} SUB2ROB_t;

`endif // HDL_VERILOG_RVV_INC_FALU_SVH

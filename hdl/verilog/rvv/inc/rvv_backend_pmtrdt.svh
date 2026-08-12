`ifndef PMTRDT_DEFINE_SVH
`define PMTRDT_DEFINE_SVH

typedef enum logic [0:0] {
  MSK0,
  MSKN
} VM_STATE_e;

typedef struct packed {
  // signals from uop
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0]         uop_pc;
`endif
  logic [`ROB_DEPTH_WIDTH-1:0]  rob_entry;
  VM_STATE_e                    vm_state;
  FUNCT6_u                      uop_funct6;
  EEW_e                         vd_eew;
  EEW_e                         vs2_eew;
  logic                         first_uop_valid;
  logic                         last_uop_valid;
} RDT_ALU_t;

typedef struct packed {
  FUNCT6_u                      uop_funct6;
  EEW_e                         vd_eew;
  logic [`VL_WIDTH-1:0]         vlmax;
} RDT_VM_t;

typedef struct packed {
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0]         uop_pc;
`endif
  logic [`ROB_DEPTH_WIDTH-1:0]  rob_entry;
  EEW_e                         vs2_eew;
  logic [`XLEN-1:0]             rs1_data;
} PMT_CTRL_t;

typedef struct packed {
  logic                         zero_valid;
  logic                         rs_valid;
  logic [`REGIDX_WIDTH-1:0]     index;
  logic [$clog2(`VLENB)-1:0]    offset;
  logic                         vs_valid;
} PMT_INFO_t;

typedef struct packed {
  logic [`BYTE_WIDTH-1:0]       data;
  logic                         valid;
} PMT_DATA_t;
`endif

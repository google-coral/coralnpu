`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`define HDL_VERILOG_RVV_DESIGN_RVV_SVH

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_DEFINE_SVH
`include "rvv_backend_define.svh"
`endif  // not defined HDL_VERILOG_RVV_DESIGN_RVV_DEFINE_SVH

`ifndef HDL_VERILOG_RVV_OPCODE_SVH
`include "rvv_backend_opcode.svh"
`endif // HDL_VERILOG_RVV_OPCODE_SVH

//
// IF stage, RVS send instruction package to Command Queue
//

// Enum type for SEW. See Table 2 in:
// https://github.com/riscv/riscv-v-spec/blob/master/v-spec.adoc#341-vector-selected-element-width-vsew20
typedef enum logic [2:0] {
  SEW8=0,
  SEW16=1,
  SEW32=2,
  SEW64=3
} RVVSEW;

// Enum type for LMUL. See:
// https://github.com/riscv/riscv-v-spec/blob/master/v-spec.adoc#vector-instruction-formats
typedef enum logic [2:0] {
  LMUL1=0,
  LMUL2=1,
  LMUL4=2,
  LMUL8=3,
  LMULRESERVED=4,
  LMUL1_8=5, // 1/8
  LMUL1_4=6, // 1/4
  LMUL1_2=7  // 1/2
} RVVLMUL;

// Enum type for vtype.vxrm: rounding mode
typedef enum logic [1:0] {
  RNU = 0,
  RNE = 1,
  RDN = 2,
  ROD = 3
} RVVXRM;

// Floating-point Rounding Mode
typedef enum logic [2:0] {
  FRNE=0,
  FRTZ=1,
  FRDN=2,
  FRUP=3,
  FRMM=4,
  FR_UNREACH_5=5,
  FR_UNREACH_6=6,
  FRDYN=7
} RVFRM;

// Floating-point Exception
typedef struct packed {
  logic nv;   
  logic dz; 
  logic of;   
  logic uf;   
  logic nx;   
} RVFEXP_t;

// The architectural configuration state of the RVV core.
typedef struct packed {
  logic                         vill; // This configuration is illegal
  logic [`VL_WIDTH-1:0]         vl;       // Max 128, need one extra bit
  logic [`VSTART_WIDTH-1:0]     vstart;
  logic [`VTYPE_VMA_WIDTH-1:0]  ma;        // 0:inactive element undisturbed, 1:inactive element agnostic
  logic [`VTYPE_VTA_WIDTH-1:0]  ta;        // 0:tail undisturbed, 1:tail agnostic
  RVVXRM                        xrm;       
  logic [`VCSR_VXSAT_WIDTH-1:0] xsat;   // rvv dont need this bit, but output this to rvs
`ifdef ZVE32F_ON
  RVFRM                         frm;
`endif
  RVVSEW                        sew;
  RVVLMUL                       lmul;
  RVVLMUL                       lmul_orig;
`ifdef ZVT_ON
  // VME (Zvt) non-tile state. Packed mtype view assembled from {tm, tk,
  // mtwiden} per ?5.1.1.2.
  // Note: The spec (v0.3) has a discrepancy: it defines tk as tk[2:0] (3 bits,
  // values 0-4) but allocates it to bits 6:5 (2 bits). We assume tk is 3 bits
  // and occupies bits 7:5, which shifts the reserved bits above it to 9:8.
  // tm is in [23:10] (14 bits), mtwiden is in [1:0] (2 bits).
  logic                         altfmt;
  logic [1:0]                   mtwiden;
  logic [13:0]                  tm;
  logic [2:0]                   tk;
`endif
} RVVConfigState;

// Enum to encode the major opcode of the instruction. See "Section 5. Vector
// Instruction Formats" of the RVV 1.0 spec.
typedef enum logic [1:0] {
  LOAD=0,
  STORE=1,
  RVV=2
} RVVOpCode;

// A decoded instruction forwarded to the RVVCore from the scalar core.
typedef struct packed {
  logic [`PC_WIDTH-1:0] pc;
  RVVOpCode             opcode;   // effectively bits [6:0] from instruction
  logic [24:0]          bits;     // bits [31:7] from instruction
} RVVInstruction;

// An command internal to the RVVCore. The immediate value of this command has
// been read from the scalar register file if necessary. It also contains
// additional data to track configuration register state (ie: SEW, LMUL, etc).
typedef struct packed {
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0] inst_pc;
`endif
  RVVOpCode             opcode;
  logic [24:0]          bits;
  logic [31:0]          rs1;
  RVVConfigState        arch_state;
} RVVCmd;

//
// DE stage, Command Queue to Uops Queue
//
// Effective MUL enum
typedef enum logic [3:0] {
  EMUL1=0,
  EMUL2=1,
  EMUL4=2,
  EMUL8=3,
  EMUL3,
  EMUL5,
  EMUL6,
  EMUL7,
  EMUL_NONE     // it means this is not supported 
} EMUL_e;

// Effective Element Width
typedef enum logic [2:0] {
  EEW_NONE,    // it means this is not supported 
  EEW1,
  EEW8, 
  EEW16,
  EEW32,
  EEW64
} EEW_e;

// the legal RVVCmd after decoding
typedef struct packed {
  RVVCmd                          cmd;
  EEW_e                           eew_vs1;
  EEW_e                           eew_vs2;
  EEW_e                           eew_vd;
`ifdef ZVT_ON
  EEW_e                           eew_mt;
`endif
  EEW_e                           eew_max;
  EMUL_e                          emul_vs1;
  EMUL_e                          emul_vs2;
  EMUL_e                          emul_vd;
  EMUL_e                          emul_max;
  logic   [`UOP_INDEX_WIDTH-1:0]  uop_vstart;         
  logic   [`UOP_INDEX_WIDTH-1:0]  uop_index_max;         
  logic   [`VL_WIDTH-1:0]         evl;
  logic                           force_vma_agnostic;
  logic                           force_vta_agnostic;
} LCMD_t;

// execution unit
typedef enum logic [4:0] {
  VEU_ALU,
  VEU_MUL,
  VEU_MAC,
  VEU_PMT,
  VEU_RDT,
  VEU_CMP,
  VEU_DIV,
  LSU,
`ifdef ZVE32F_ON
  VEU_FMA,
  VEU_FCVT,
  VEU_FRDT,
  VEU_FNCMP,
  VEU_FCMP,
  VEU_FDIV,
  VEU_FTBL,
`endif
`ifdef ZVT_ON
  VME,
  VMELSU,
`endif
  VEU_MISC
} EXE_UNIT_e;

// when EXE_UNIT_e is LSU, it identifys what LSU instruction, unit-stride load or indexed store or ..? based on inst_encoding[31:26]
typedef enum logic [2:0] {
  US,         // Unit-Stride
  IU,         // Indexed Unordered
  CS,         // Constant Stride
  IO          // Indexed Ordered
`ifdef ZVT_ON
  ,TILELDST
`endif
} LSU_MOP_e;

// It identifys what unit-stride instruction when LSU_MOP_e=US, based on inst_encoding[24:20]
typedef enum logic [1:0] {
  US_US,         // Unit-Stride load/store
  US_WR,         // Whole Register load/store
  US_MK,         // MasK load/store, EEW=8(inst_encoding[14:12]=3'b000)
  US_FF          // Faul-only-First load
} LSU_UMOP_e;

// segment load/store 
typedef enum logic [0:0] {
  IS_SEGMENT,
  NONE      
} LSU_IS_SEG_e;

// combine those signals to LSU_TYPE
typedef struct packed {
  LSU_MOP_e         lsu_mop;
  LSU_UMOP_e        lsu_umop;
  LSU_IS_SEG_e      lsu_is_seg;
} LSU_TYPE_t;

// function opcode
typedef union packed {
  logic   [`FUNCT6_WIDTH-1:0]         ari_funct6;
  LSU_TYPE_t                          lsu_funct6;
} FUNCT6_u;

// uop classification used for dispatch rule
typedef enum logic [2:0] {
  XXX=0,
  XXV=1,
  XVX=2,
  XVV=3,
  VXX=4,
  VXV=5,
  VVX=6,
  VVV=7
} UOP_CLASS_e;

// Destination data struct
typedef enum logic [1:0] {
  NOWRITE,
  VRF,
  XRF
`ifdef ZVE32F_ON
  ,FRF
`endif
} W_DATA_TYPE_e;

// the uop struct stored in Uops Queue
typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]         uop_pc;
  logic                           res_updating_end; 
`endif
  logic   [`FUNCT3_WIDTH-1:0]     uop_funct3;
  FUNCT6_u                        uop_funct6;
  EXE_UNIT_e                      uop_exe_unit; 
  UOP_CLASS_e                     uop_class;   
  logic                           lsu_is_store;
  RVVConfigState                  vector_csr;  
  logic   [`VL_WIDTH-1:0]         vs_evl;             
  logic                           ignore_vma;
  logic                           ignore_vta;
  logic                           force_vma_agnostic; 
  logic                           force_vta_agnostic; 
  logic                           vm;                 
  logic                           v0_valid;           
  logic   [`REGIDX_WIDTH-1:0]     dst_index;
  EEW_e                           vd_eew;  
  logic                           vd_valid;
  logic                           vs3_valid;          
  logic                           xd_valid; 
`ifdef ZVE32F_ON
  logic                           fd_valid; 
`endif
`ifdef ZVT_ON
  logic                           mt_valid; 
  EEW_e                           mt_eew;
`endif
  logic   [`REGIDX_WIDTH-1:0]     vs1;              
  EEW_e                           vs1_eew;            
  logic                           vs1_valid;
  logic   [`REGIDX_WIDTH-1:0]     vs2_index; 	        
  EEW_e                           vs2_eew;
  logic                           vs2_valid;
  logic   [`XLEN-1:0] 	          rs1_data;           
  logic        	                  rs1_data_valid;    
  logic   [`UOP_INDEX_WIDTH-1:0]  uop_index;          
  logic                           first_uop_valid;    
  logic                           last_uop_valid;     
  logic   [$clog2(`EMUL_MAX)-1:0] seg_field_index;    
  logic                           pshrob_valid;       
  logic                           pshlsu_valid;
} UOP_QUEUE_t;    

// specify whether the current byte belongs to 'prestart' or 'body-inactive' or 'body-active' or 'tail'
typedef enum logic [1:0] {
  NOT_CHANGE    = 2'b00,      // the byte is not changed, which may belong to 'prestart' or superfluous element in widening/narrowing uop
  TAIL          = 2'b01,      // tail byte
  BODY_INACTIVE = 2'b10,      // body-inactive byte
  BODY_ACTIVE   = 2'b11       // body-active byte
} BYTE_TYPE_e;

// trap handle
typedef enum logic [1:0] {
  TRAP_LSU,           
  TRAP_LSU_FF       
} TRAP_INFO_e;

// the max number of byte in a vector register is VLENB
typedef BYTE_TYPE_e [`VLENB-1:0]      BYTE_TYPE_t;

typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  FUNCT6_u                            uop_funct6;  
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3;
  logic                               is_cmp;
  logic   [`VSTART_WIDTH-1:0]         vstart;
  logic   [`VL_WIDTH-1:0]             vl;       
  logic                               vm;               
  RVVXRM                              vxrm;       
  logic   [`VLEN-1:0]                 v0_data;
  logic                               v0_data_valid;
  logic   [`VLEN-1:0]                 vd_data;
  logic                               vd_data_valid;
  EEW_e                               vd_eew;  
  logic   [`REGIDX_WIDTH-1:0]  vs1;              
  logic   [`VLEN-1:0]                 vs1_data;           
  logic                               vs1_data_valid; 
  logic        	                      rs1_data_valid;                                   
  logic   [`VLEN-1:0]                 vs2_data;	        
  logic                               vs2_data_valid;  
  EEW_e                               vs2_eew;
  logic                               first_uop_valid;     
  logic                               last_uop_valid;
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]  uop_index;      
} ALU_RS_t;    

// DIV reservation station struct
typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  FUNCT6_u                            uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3;
  logic                               is_div;
  logic   [`VLEN-1:0]                 vs1_data;           
  logic                               vs1_data_valid; 
  logic        	                      rs1_data_valid;      
  logic   [`VLEN-1:0]                 vs2_data;	        
  logic                               vs2_data_valid;  
  EEW_e                               vs2_eew;
`ifdef ZVE32F_ON
  RVFRM                               frm;
  logic   [`REGIDX_WIDTH-1:0]         vs1;              
`endif
} DIV_RS_t; 

// DIV reservation station struct
typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  FUNCT6_u                            uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3;
  logic   [`VLEN-1:0]                 vs1_data;           
  logic                               vs1_data_valid; 
  logic        	                      rs1_data_valid;      
  logic   [`VLEN-1:0]                 vs2_data;	        
  logic                               vs2_data_valid;  
  EEW_e                               vs2_eew;
`ifdef ZVE32F_ON
  RVFRM                               frm;
  logic   [`REGIDX_WIDTH-1:0]         vs1;              
`endif
} DIV_SUB_t;

// MUL and MAC reservation station struct
typedef struct packed {   
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  FUNCT6_u                            uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3;
  RVVXRM                              vxrm;       
  logic   [`VLEN-1:0]                 vs1_data;           
  logic                               vs1_data_valid; 
  logic          	                    rs1_data_valid;   
  logic   [`VLEN-1:0]                 vs2_data;	        
  logic                               vs2_data_valid; 
  EEW_e                               vs2_eew; 
  logic   [`VLEN-1:0]                 vs3_data;	
  logic                               vs3_data_valid; 
  logic                               uop_index;
} MUL_RS_t;    

// PMT and RDT reservation station struct
typedef struct packed {   
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  EXE_UNIT_e                          uop_exe_unit; 
  FUNCT6_u                            uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3;
  logic   [`VL_WIDTH-1:0]             vl;       
  logic                               vm;
  logic   [`VL_WIDTH-1:0]             vlmax;       
  logic   [`VLEN-1:0]                 v0_data;
  EEW_e                               vs1_eew;
  logic   [`VLEN-1:0]                 vs1_data;          
  logic                               vs1_data_valid; 
  EEW_e                               vs2_eew;
  logic   [`VLEN-1:0]                 vs2_data;	        
  BYTE_TYPE_t                         vs2_type;
  logic   [`REGIDX_WIDTH-1:0]         vs2_index;
  EEW_e                               vd_eew;  
  logic   [`REGIDX_WIDTH-1:0]         dst_index;
  logic   [`XLEN-1:0] 	              rs1_data;         
  logic                               first_uop_valid;     
  logic                               last_uop_valid;     
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]  uop_index;      
`ifdef ZVE32F_ON
  RVFRM                               frm;
`endif
} PMT_RDT_RS_t;    

// LSU reservation station struct
typedef struct packed {   
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic                               vidx_valid; 
  logic   [`REGIDX_WIDTH-1:0]         vidx_addr;
  logic   [`VLEN-1:0]                 vidx_data;            // vs2        
  logic                               vregfile_read_valid; 
  logic   [`REGIDX_WIDTH-1:0]         vregfile_read_addr;
  logic   [`VLEN-1:0]                 vregfile_read_data;   // vs3       
  logic                               v0_valid;
  logic   [`VLENB-1:0]                v0_data;              // byte strobe signal for mask load/store. 
                                                            // v0[i]=1 means vd/vs3[8*i +: 8] data is valid. 
} UOP_RVV2LSU_t;    

 // FMA reservation station struct
typedef struct packed {   
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  FUNCT6_u                            uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3;
  EXE_UNIT_e                          uop_exe_unit; 
  logic   [`VSTART_WIDTH-1:0]         vstart;
  logic   [`VL_WIDTH-1:0]             vl;       
  logic                               vm;               
  RVFRM                               frm;
  logic   [`VLENW*`EMUL_MAX-1:0]      v0_data;
  logic                               v0_data_valid;
  logic   [`REGIDX_WIDTH-1:0]         vs1;              
  logic   [`VLEN-1:0]                 vs1_data;           
  logic                               vs1_data_valid; 
  logic   [`VLEN-1:0]                 vs2_data;	        
  logic                               vs2_data_valid; 
  EEW_e                               vs2_eew; 
  logic   [`VLEN-1:0]                 vs3_data;	
  logic                               vs3_data_valid; 
  logic   [`XLEN-1:0] 	              rs1_data;          
  logic          	                    rs1_data_valid;   
  logic                               last_uop_valid;
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]  uop_index;      
} FALU_RS_t;  

//
// EX stage, 
//
// send PU's result to ROB
typedef struct packed {
`ifdef TB_SUPPORT
  logic     [`PC_WIDTH-1:0]           uop_pc;
`endif
  logic     [`ROB_DEPTH_WIDTH-1:0]    rob_entry;
  logic     [`VLEN-1:0]               w_data;             // when w_type=XRF, w_data[`XLEN-1:0] will store the scalar result
  logic                               w_valid;
  logic     [`VLENB-1:0]              vsaturate;
`ifdef ZVE32F_ON
  RVFEXP_t  [`VLENB-1:0]              fpexp;
`endif
} PU2ROB_t;  

// lsu uop info to remap rob_entry for UOP_LSU2RVV_t
typedef struct packed {   
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic                               valid;
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry;
  logic                               lsu_is_store;
  logic	  [`REGIDX_WIDTH-1:0]         vregfile_write_addr;  
} LSU_MAP_INFO_t; 

// LSU feedback to RVV
typedef struct packed {   
`ifdef TB_SUPPORT
  // To trace wave
  logic   [`PC_WIDTH-1:0]             uop_pc;
  logic   [`UOP_INDEX_WIDTH-1:0]      uop_index;         
`endif
  // For load data
  logic                               vregfile_write_valid;
  logic	  [`REGIDX_WIDTH-1:0] 	      vregfile_write_addr;  
  logic	  [`VLEN-1:0] 			          vregfile_write_data;  	// vd   
  // vregfile_write_data[`VLEN-1:ff_tail_index*8] is treated as TAIL.
  logic   [$clog2(`VLENB):0]          ff_tail_index;
  // Store done signal to help ROB retire the store uop
  logic                               lsu_vstore_last;
} UOP_LSU2RVV_t;  

typedef struct packed {   
  UOP_LSU2RVV_t                       uop_lsu2rvv;
  logic                               trap_valid;
} UOP_LSU_t;  

typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic                               w_valid;            // write valid
  logic [`VLEN-1:0]                   w_data;             // write data; w_data[`XLEN-1:0] is scalar result if write type is XRF
  logic [$clog2(`VLENB):0]            ff_tail_index;
  logic [`VLENB-1:0]                  vsaturate;
`ifdef ZVE32F_ON
  RVFEXP_t  [`VLENB-1:0]              fpexp;
`endif
} RES_ROB_t;

// send uop to ROB
typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
  logic                               res_updating_end; 
`endif
  logic   [`REGIDX_WIDTH-1:0]         w_index;            //wr addr
  W_DATA_TYPE_e                       w_type;             //write type: 0 for VRF, 1 for XRF
  BYTE_TYPE_t                         byte_type;          //wr Byte mask
  logic                               is_ff;
  RVVConfigState                      vector_csr;         //Receive Vstart, vlen,... And need to update vcsr when trap
  logic                               last_uop_valid;
} DP2ROB_t;

// send ROB info to DP
typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic                               valid;              //entry valid
  logic                               w_valid;            //vd valid
  logic   [`REGIDX_WIDTH-1:0]         w_index;            //vd addr
  W_DATA_TYPE_e                       w_type;             //write type: 0 for VRF, 1 for XRF
  logic   [`VLEN-1:0]                 w_data;             //when w_type=XRF, w_data[`XLEN-1:0] will store the scalar result
  BYTE_TYPE_t                         byte_type;          //wr Byte mask
  RVVConfigState                      vector_csr;         //Receive Vstart, vlen,... And need to update vcsr when trap
} ROB2DP_t;

typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
  logic                               last_uop_valid;
  logic                               res_updating_end; 
`endif
  logic                               w_valid;            //entry valid
  logic   [`REGIDX_WIDTH-1:0]         w_index;            //wr addr
  logic   [`VLEN-1:0]                 w_data;             //when w_type=XRF, w_data[`XLEN-1:0] will store the scalar result
  W_DATA_TYPE_e                       w_type;             //to VRF or XRF
  BYTE_TYPE_t                         vd_type;            //wr Byte mask
  logic                               trap_flag;          //whether this entry in a trap
  RVVConfigState                      vector_csr;         //Receive Vstart, vlen,... And need to update vcsr when trap
  logic   [`VLENB-1:0]                vxsaturate;         //Update saturation bit
`ifdef ZVE32F_ON
  RVFEXP_t  [`VLENB-1:0]              fpexp;
`endif
} ROB2RT_t;  

// the rob struct stored in ROB
typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]             uop_pc;
`endif
  logic                               valid;              // entry valid
  DP2ROB_t                            uop_info;           // Uop information
  RES_ROB_t                           uop_res;            // Uop result
  logic                               uop_done;           // Uop is finished.
  logic                               trap;
} ROB_t;

//
// Retire stage
//
// write back to XRF/FRF
typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]       uop_pc;
`endif
  logic   [`REGIDX_WIDTH-1:0]   rt_index; 
  logic   [`XLEN-1:0]           rt_data; 
}RT2RVS_t;

// write back to VRF
typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]       uop_pc;
`endif
  logic   [`REGIDX_WIDTH-1:0]   rt_index; 
  logic   [`VLEN-1:0]           rt_data;
  logic   [`VLENB-1:0]          rt_strobe; 
}RT2VRF_t;

// ZVT
`ifdef ZVT_ON
typedef struct packed {
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0]    		  uop_pc;		
  logic [2:0]	                  uop_index;	
`endif
  logic [`VLEN-1:0]   			    r_data;		
} UOP_VME2LSU_t;

typedef struct packed {
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0]    		  uop_pc;		
  logic [2:0]	                  uop_index;	
`endif
  logic [`VLEN-1:0]   			    w_data;		
} UOP_LSU2VME_t;

typedef struct packed {
  logic [$clog2(`NUM_MT)-1:0]   tile;
  logic                         pattern;
  logic [$clog2(`TE)-1:0]       index;
} TSS_t;

typedef enum logic [1:0] {
  FPMUL,        // src2 is fp 
  INTMUL,       // src2 is signed int
  UINTMUL       // src2 is unsigned int
} PEOPCODE_e;

typedef struct packed {
`ifdef TB_SUPPORT
  logic   [`PC_WIDTH-1:0]         uop_pc;
`endif
  logic   [`ROB_DEPTH_WIDTH-1:0]  rob_entry;
  FUNCT6_u                        uop_funct6;  
  logic   [`FUNCT3_WIDTH-1:0]     uop_funct3;
  logic   [`REGIDX_WIDTH-1:0]     vs2;
  logic                           is_lsu;
  logic                           is_store;
  logic   [`VSTART_WIDTH-1:0]     vstart;
  logic                           altfmt;
  logic   [1:0]                   mtwiden;
  logic   [13:0]                  tm;
  logic   [$clog2(`TE):0]         vl;      
  logic   [2:0]                   tk;
  RVVSEW                          sew;
  EEW_e                           eew_mt;
  fpnew_pkg::roundmode_e          rndMode; 
  TSS_t                           tss;
  logic   [`VLEN-1:0]             vs1_data;           
  logic   [`VLEN-1:0]             vs2_data;	        
  logic   [`REGIDX_WIDTH-1:0]     dst_index;
  logic                           first_uop_valid;
  logic                           last_uop_valid;
  logic   [$clog2(`EMUL_MAX)-1:0] uop_index; 
} ZVT_RS_t;

typedef struct packed {
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0]                         uop_pc;
`endif
  logic [`TE/2*`COMPRATIO-1:0][`WORD_WIDTH-1:0] va;
  logic [`TE/2*`COMPRATIO-1:0][3:0]             vaMask;    
  fpnew_pkg::roundmode_e                        rndMode;
  PEOPCODE_e                                    op;    
  logic                                         opMod;
  fpnew_pkg::fp_format_e                        fsrcFmt;
  fpnew_pkg::int_format_e                       isrcFmt; 
  fpnew_pkg::fp_format_e                        fdstFmt; 
  fpnew_pkg::int_format_e                       idstFmt;    
  logic [$clog2(`NUM_MT)-1:0]                   readMtIdx; 
  logic [$clog2(`PROCESS_DELAY)-1:0]            readMtId;        
  logic                                         lastUopVld;
} PEVAINFO_t;

typedef struct packed {
  logic [`TE/2-1:0][`WORD_WIDTH-1:0]            vb;
  logic [`TE/2-1:0][3:0]                        vbMask;       
} PEVBINFO_t;

typedef struct packed {
  PEVAINFO_t                                    vaInfo;
  PEVBINFO_t                                    vbInfo;
} BLKCMD_t;

typedef struct packed {
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0]                         uop_pc;
`endif
  fpnew_pkg::roundmode_e                        rndMode;
  PEOPCODE_e                                    op;   
  fpnew_pkg::fp_format_e                        fdstFmt; 
  fpnew_pkg::int_format_e                       idstFmt; 
  logic [$clog2(`NUM_MT)-1:0]                   readMtIdx; 
  logic [$clog2(`PROCESS_DELAY)-1:0]            readMtId;
  logic                                         lastUopVld;
} MULBULKTAG_t;

typedef struct packed {
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][`WORD_WIDTH-1:0]  res;
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][3:0]              resMask;  
  fpnew_pkg::status_t [`TE/2*`COMPRATIO-1:0][`TE/2-1:0]     status;
  MULBULKTAG_t                                              tag; 
} MULBULKRES_t;

typedef struct packed {
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0]                                     uop_pc;
`endif
  fpnew_pkg::status_t [`TE/2*`COMPRATIO-1:0][`TE/2-1:0]     status;
  logic [$clog2(`NUM_MT)-1:0]                               writeMtIdx; 
  logic [$clog2(`PROCESS_DELAY)-1:0]                        writeMtId;
  logic                                                     lastUopVld;
} ADDERTAG_t;

typedef struct packed {
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0]                               inst_pc;
`endif
  logic                                               isStore;
  logic                                               isLoad;
  logic                                               isMv2Vme;
  logic                                               isZero;
  logic                                               isPe;
`ifdef RVVI_ON
  logic [$clog2(`TE)-1:0]                             tssIndex;
  logic                                               tssPattern;
  logic [$clog2(`NUM_MT)-1:0]                         mt_index;
  EEW_e                                               eew_mt;
`endif
} VME_RTCMD_t;

typedef struct packed {
  logic                                                     Vld;
`ifdef RVVI_ON
  logic [3:0][$clog2(`NUM_MT)-1:0]                          rvviMtIdx;
  logic [3:0][`NUM_SUBTILE/2-1:0]                           rvviSubVld;
  logic [3:0][`NUM_SUBTILE/2-1:0][$clog2(`NUM_SUBTILE)-1:0] rvviSubIdx;
  logic [3:0][`NUM_SUBTILE/2-1:0][`SUBTILE_SIZE*8-1:0]      rvviData;
`endif  
} MT_INFO_t;

`ifdef RVVI_ON
typedef struct packed {
  logic [`PC_WIDTH-1:0]                               uop_pc;
  logic [$clog2(`NUM_MT)-1:0]                         mtIdx;
} PE_RTINFO_t;
`endif

typedef struct packed {
`ifdef TB_SUPPORT
  logic [`PC_WIDTH-1:0]                               inst_pc;
`endif
  logic                                               isStore;
`ifdef RVVI_ON
  logic [3:0]                                         mtIdxVld;
  logic [3:0][$clog2(`NUM_MT)-1:0]                    mtIdx;
  logic [3:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0]  mtData;       
`endif
} VMERT_t;
`endif  // ZVT_ON 

`endif  // HDL_VERILOG_RVV_DESIGN_RVV_SVH

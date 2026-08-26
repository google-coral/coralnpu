`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_retire(
  rob2rt_write_valid,
  rob2rt_write_data,
  rt2rob_write_ready,
  rt2xrf_write_valid,
  rt2rvs_write_data,
  rvs2rt_write_ready,
`ifdef ZVE32F_ON
  rt2frf_write_valid,
  frf2rt_write_ready,
`endif
  rt2vrf_write_valid,
  rt2vrf_write_data,
  rt2vcsr_write_valid,
  rt2vcsr_write_data,
  vcsr2rt_write_ready,
  rt2vxsat_write_valid,
  rt2vxsat_write_data,
  vxsat2rt_write_ready,
`ifdef ZVT_ON
  zvtFpexpVld,
  zvtFpexp,
  zvtFpexpRdy,
`endif
`ifdef ZVE32F_ON
  rt2fcsr_write_valid,
  rt2fcsr_write_data,
  fcsr2rt_write_ready,
`endif
  rvvrob2rt_valid,
  rvvrob2rt_data
`ifdef RVVI_ON
  ,vrf_data
`endif
);
// ROB dataout
    input   logic    [`NUM_RT_UOP-1:0]          rob2rt_write_valid;
    input   ROB2RT_t [`NUM_RT_UOP-1:0]          rob2rt_write_data;
    output  logic    [`NUM_RT_UOP-1:0]          rt2rob_write_ready;

// write back to XRF
    output  logic    [`NUM_RT_UOP-1:0]          rt2xrf_write_valid;
    output  RT2RVS_t [`NUM_RT_UOP-1:0]          rt2rvs_write_data;
    input   logic    [`NUM_RT_UOP-1:0]          rvs2rt_write_ready;

// write back to FRF
`ifdef ZVE32F_ON
    output  logic    [`NUM_RT_UOP-1:0]          rt2frf_write_valid;
    input   logic    [`NUM_RT_UOP-1:0]          frf2rt_write_ready;
`endif

// write back to VRF
    output  logic    [`NUM_RT_UOP-1:0]          rt2vrf_write_valid;
    output  RT2VRF_t [`NUM_RT_UOP-1:0]          rt2vrf_write_data;

// write to update vcsr
    output  logic                               rt2vcsr_write_valid;
    output  RVVConfigState                      rt2vcsr_write_data;
    input   logic                               vcsr2rt_write_ready;

// vxsat
    output  logic                               rt2vxsat_write_valid;
    output  logic   [`VCSR_VXSAT_WIDTH-1:0]     rt2vxsat_write_data;
    input   logic                               vxsat2rt_write_ready;

`ifdef ZVT_ON
// ZVT Floating-point exception
    input   logic                               zvtFpexpVld;
    input   RVFEXP_t                            zvtFpexp;
    output  logic                               zvtFpexpRdy;
`endif

`ifdef ZVE32F_ON
// Floating-point exception
    output  logic                               rt2fcsr_write_valid;
    output  RVFEXP_t                            rt2fcsr_write_data;
    input   logic                               fcsr2rt_write_ready;
`endif

// Retire information for RVVI.
    output  logic    [`NUM_RT_UOP-1:0]          rvvrob2rt_valid; // always ready to receive.
    output  ROB2RT_t [`NUM_RT_UOP-1:0]          rvvrob2rt_data;  
`ifdef RVVI_ON
    input   logic    [`NUM_VRF-1:0][`VLEN-1:0]  vrf_data;
`endif

////////////Wires & Regs  ///////////////
logic [`NUM_RT_UOP-1:0]                         w_valid_chkTrap;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]             w_strobe;
logic [`NUM_RT_UOP-1:0][`REGIDX_WIDTH-1:0]      w_addr;
logic [`NUM_RT_UOP-1:0]                         w_valid;
logic [`NUM_RT_UOP-1:0][`VLEN-1:0]              w_data;
logic [`NUM_RT_UOP-1:0]                         trap_flag;
RVVConfigState  [`NUM_RT_UOP-1:0]               w_vcsr;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]             w_vxsaturate;
logic [`NUM_RT_UOP-1:0][`VCSR_VXSAT_WIDTH-1:0]  w_vxsat;
`ifdef ZVE32F_ON
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]             fpexp_nv_lanes;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]             fpexp_dz_lanes;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]             fpexp_of_lanes;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]             fpexp_uf_lanes;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]             fpexp_nx_lanes;
logic [`NUM_RT_UOP-1:0]                         fpexp_nv;
logic [`NUM_RT_UOP-1:0]                         fpexp_dz;
logic [`NUM_RT_UOP-1:0]                         fpexp_of;
logic [`NUM_RT_UOP-1:0]                         fpexp_uf;
logic [`NUM_RT_UOP-1:0]                         fpexp_nx;
RVFEXP_t  [`NUM_RT_UOP-1:0]                     w_fpexp;
logic     [`NUM_RT_UOP-1:0]                     w_fpexp_vld;
logic     [`NUM_RT_UOP-1:0]                     fcsr2rt_ready;
`endif
logic [`NUM_RT_UOP-1:1][`NUM_RT_UOP-1:0]        waw;
logic [`NUM_RT_UOP-1:0]                         hit_waw;
logic [`NUM_RT_UOP-1:0]                         vrfres_valid;
logic [`NUM_RT_UOP-1:0][`VLEN-1:0]              vrfres;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]             vrfres_strobe;
logic [`NUM_RT_UOP-1:0]                         w_vrf_valid;
logic [`NUM_RT_UOP-1:0]                         w_vrf;
logic [`NUM_RT_UOP-1:0]                         w_xrf_valid;
logic [`NUM_RT_UOP-1:0]                         w_xrf;
`ifdef ZVE32F_ON
logic [`NUM_RT_UOP-1:0]                         w_frf_valid;
logic [`NUM_RT_UOP-1:0]                         w_frf;
`endif
logic [`NUM_RT_UOP-1:0]                         vxsat2rt_ready;

genvar                                          i,j;

/////////////////////////////////
/////////////Main////////////////
/////////////////////////////////
generate
  for(j=0;j<`NUM_RT_UOP;j++) begin : gen_inter_logic
    assign w_addr[j]    = rob2rt_write_data[j].w_index;
    assign w_valid[j]   = rob2rt_write_data[j].w_valid;
    assign w_data[j]    = rob2rt_write_data[j].w_data;
    assign trap_flag[j] = rob2rt_write_data[j].trap_flag;
    assign w_vcsr[j]    = rob2rt_write_data[j].vector_csr;

    for (i=0;i<`VLENB;i++) begin : gen_vlenb
      assign w_strobe[j][i]       = rob2rt_write_data[j].vd_type[i]==BODY_ACTIVE;
      assign w_vxsaturate[j][i]   = w_strobe[j][i] & rob2rt_write_data[j].vxsaturate[i];
      `ifdef ZVE32F_ON
      assign fpexp_nv_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].nv; 
      assign fpexp_dz_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].dz; 
      assign fpexp_of_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].of; 
      assign fpexp_uf_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].uf; 
      assign fpexp_nx_lanes[j][i] = w_strobe[j][i] & rob2rt_write_data[j].fpexp[i].nx; 
      `endif
    end

    assign w_vxsat[j]     = |w_vxsaturate[j];
    `ifdef ZVE32F_ON
    assign fpexp_nv[j]    = |fpexp_nv_lanes[j];
    assign fpexp_dz[j]    = |fpexp_dz_lanes[j];
    assign fpexp_of[j]    = |fpexp_of_lanes[j];
    assign fpexp_uf[j]    = |fpexp_uf_lanes[j];
    assign fpexp_nx[j]    = |fpexp_nx_lanes[j];
    assign w_fpexp[j].nv  = fpexp_nv[j];
    assign w_fpexp[j].dz  = fpexp_dz[j];
    assign w_fpexp[j].of  = fpexp_of[j];
    assign w_fpexp[j].uf  = fpexp_uf[j];
    assign w_fpexp[j].nx  = fpexp_nx[j];
    assign w_fpexp_vld[j] = |w_fpexp[j];
    `endif

    if(j==0) begin : gen_0
      assign w_valid_chkTrap[0] = !trap_flag[0] && rob2rt_write_valid[0];
    end else begin : gen_j
      assign w_valid_chkTrap[j] = !(|trap_flag[j-1:0]) && rob2rt_write_valid[j];
    end

  // writing different register
    assign w_vrf[j]       = (rob2rt_write_data[j].w_type==VRF) && rob2rt_write_data[j].w_valid;
    assign w_vrf_valid[j] = w_valid_chkTrap[j] && w_vrf[j];
    assign w_xrf[j]       = (rob2rt_write_data[j].w_type==XRF) && rob2rt_write_data[j].w_valid;
    assign w_xrf_valid[j] = w_valid_chkTrap[j] && w_xrf[j];
  `ifdef ZVE32F_ON
    assign w_frf[j]       = (rob2rt_write_data[j].w_type==FRF) && rob2rt_write_data[j].w_valid;
    assign w_frf_valid[j] = w_valid_chkTrap[j] && w_frf[j];
  `endif
  end

// VRF WAW
  assign vrfres[0]        = w_data[0];
  assign vrfres_strobe[0] = w_strobe[0];

  for(j=1;j<`NUM_RT_UOP;j++) begin: process_waw
    rvv_backend_retire_waw #(
      .UOP_NUM    (j+1)
    ) u_process_waw (
      .valid      (w_vrf_valid[j:0]&rt2rob_write_ready[j:0]),
      .w_index    (w_addr[j:0]),
      .w_strobe   (w_strobe[j:0]),
      .w_data     (w_data[j:0]),
      .waw        (waw[j]),
      .res        (vrfres[j]),
      .res_strobe (vrfres_strobe[j])
    );
  end

  always_comb begin
    hit_waw = 'b0;
    for(int i=1;i<`NUM_RT_UOP;i++) begin
      hit_waw = hit_waw | waw[i];
    end
  end
  
  // mask the existing WAW uop
  assign vrfres_valid = w_vrf_valid & rt2rob_write_ready & (~hit_waw);

// retire
  // To VCSR
  assign rt2vcsr_write_valid  = rob2rt_write_valid[0] && trap_flag[0] && vcsr2rt_write_ready;
  assign rt2vcsr_write_data   = w_vcsr[0];

  // To vxsat
  assign vxsat2rt_ready       = ~(w_vrf_valid&w_vxsat) | {`NUM_RT_UOP{vxsat2rt_write_ready}}; 
  assign rt2vxsat_write_valid = |(w_vrf_valid&rt2rob_write_ready&w_vxsat) && !trap_flag[0];
  assign rt2vxsat_write_data  = rt2vxsat_write_valid;

`ifdef ZVE32F_ON
  // To FCSR[4:0]
  assign fcsr2rt_ready          = ~w_fpexp_vld | {`NUM_RT_UOP{fcsr2rt_write_ready}};
  `ifdef ZVT_ON
  assign zvtFpexpRdy            = ~zvtFpexpVld | fcsr2rt_write_ready;
  `endif
  assign rt2fcsr_write_valid    = trap_flag[0] ? 'b0 : |(w_fpexp_vld & rob2rt_write_valid & rt2rob_write_ready)
                                                      `ifdef ZVT_ON
                                                       || zvtFpexpVld & fcsr2rt_write_ready
                                                      `endif
                                                       ;

  assign rt2fcsr_write_data.nv  = |(fpexp_nv & rob2rt_write_valid & rt2rob_write_ready)
                                  `ifdef ZVT_ON
                                   || zvtFpexp.nv
                                  `endif
                                  ;
  assign rt2fcsr_write_data.dz  = |(fpexp_dz & rob2rt_write_valid & rt2rob_write_ready);
  assign rt2fcsr_write_data.of  = |(fpexp_of & rob2rt_write_valid & rt2rob_write_ready)
                                  `ifdef ZVT_ON
                                   || zvtFpexp.of
                                  `endif
                                  ;
  assign rt2fcsr_write_data.uf  = |(fpexp_uf & rob2rt_write_valid & rt2rob_write_ready);
  assign rt2fcsr_write_data.nx  = |(fpexp_nx & rob2rt_write_valid & rt2rob_write_ready);
`endif
  
  always_comb begin
    if(trap_flag[0])
      rt2rob_write_ready[0] = vcsr2rt_write_ready;
    else if(rob2rt_write_data[0].w_type==VRF) begin
      rt2rob_write_ready[0] = vxsat2rt_ready[0]
                              `ifdef ZVE32F_ON
                              && fcsr2rt_ready[0]
                              `endif
                              ;
    end
    else begin
    `ifdef ZVE32F_ON
      rt2rob_write_ready[0] = (rob2rt_write_data[0].w_type==XRF) ? rvs2rt_write_ready[0] : frf2rt_write_ready[0] & fcsr2rt_ready[0];
    `else
      rt2rob_write_ready[0] = rvs2rt_write_ready[0];
    `endif
    end
  end

  for(j=1;j<`NUM_RT_UOP;j++) begin
    always_comb begin
      if(rob2rt_write_data[j].w_type==VRF) begin
        rt2rob_write_ready[j] = rt2rob_write_ready[j-1] & (vxsat2rt_ready[j]
                                                          `ifdef ZVE32F_ON
                                                          && fcsr2rt_ready[j]
                                                          `endif
                                                          );
      end
      else begin
      `ifdef ZVE32F_ON
        rt2rob_write_ready[j] = (rob2rt_write_data[j].w_type==XRF) 
                                ? rt2rob_write_ready[j-1] & rvs2rt_write_ready[j] 
                                : rt2rob_write_ready[j-1] & frf2rt_write_ready[j] & fcsr2rt_ready[j];
      `else
        rt2rob_write_ready[j] = rt2rob_write_ready[j-1] & rvs2rt_write_ready[j];
      `endif
      end
    end
  end

  for(j=0;j<`NUM_RT_UOP;j++) begin : gen_rt2vrf_write
    always_comb begin
      if(vrfres_valid[j]) begin
        rt2vrf_write_valid[j]           = 1'b1; 

        `ifdef TB_SUPPORT
        rt2vrf_write_data[j].uop_pc     = rob2rt_write_data[j].uop_pc;
        `endif
        rt2vrf_write_data[j].rt_index   = w_addr[j];
        rt2vrf_write_data[j].rt_data    = vrfres[j];
        rt2vrf_write_data[j].rt_strobe  = vrfres_strobe[j];
      end
      else begin
        rt2vrf_write_valid[j]           = 'b0;     
        rt2vrf_write_data[j]            = 'b0;
      end
    end
  end

  for(j=0;j<`NUM_RT_UOP;j++) begin : gen_rt2rob_write
    always_comb begin
      `ifdef ZVE32F_ON
      if(w_xrf[j]|w_frf[j]) begin
      `else
      if(w_xrf[j]) begin
      `endif
        rt2xrf_write_valid[j]           = w_xrf[j];     
        `ifdef ZVE32F_ON
        rt2frf_write_valid[j]           = w_frf[j]; 
        `endif

        `ifdef TB_SUPPORT
        rt2rvs_write_data[j].uop_pc     = rob2rt_write_data[j].uop_pc;
        `endif
        rt2rvs_write_data[j].rob_tag    = rob2rt_write_data[j].rob_tag;
        rt2rvs_write_data[j].rt_index   = w_addr[j];
        rt2rvs_write_data[j].rt_data    = w_data[j][31:0];
      end
      else begin
        rt2xrf_write_valid[j]           = 'b0;     
        `ifdef ZVE32F_ON
        rt2frf_write_valid[j]           = 'b0; 
        `endif
        rt2rvs_write_data[j]            = 'b0;
      end
    end
  end
endgenerate

// retire information for the RetirementBuffer
  always_comb begin
    for(int j=0;j<`NUM_RT_UOP;j++) begin
      rvvrob2rt_valid[j]        = rob2rt_write_valid[j] &
                                  rt2rob_write_ready[j] &
                                  rob2rt_write_data[j].w_valid & 
                                  rob2rt_write_data[j].res_updating_end;

    
      rvvrob2rt_data[j]         = rob2rt_write_data[j];
      rvvrob2rt_data[j].w_valid = rvvrob2rt_valid[j];  
    `ifndef RVVI_ON
      rvvrob2rt_data[j].w_data  = 'b0;
    `endif

      if(rob2rt_write_data[j].w_type==VRF) begin
        for(int i=0;i<`VLENB;i++) begin
          rvvrob2rt_data[j].vd_type                             = {`VLENB{BODY_ACTIVE}};
        `ifdef RVVI_ON
          rvvrob2rt_data[j].w_data[i*`BYTE_WIDTH+:`BYTE_WIDTH]  = vrfres_strobe[j][i] 
                                                                ? vrfres[j][i*`BYTE_WIDTH+:`BYTE_WIDTH] 
                                                                : vrf_data[rob2rt_write_data[j].w_index][i*`BYTE_WIDTH+:`BYTE_WIDTH];
        `endif
        end
      end
    end
  end

endmodule

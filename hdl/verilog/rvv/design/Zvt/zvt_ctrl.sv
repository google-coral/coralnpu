`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_ctrl (
  clk,
  rst_n,
  uopVld,
  uop,
  uopRdy,
  res_vme2rvv_vld,
  res_vme2rvv,
  res_vme2rvv_rdy,
  vmelsuVld,
  vmelsu,
  vmelsuRdy,
  vmelsuresVld,
  vmelsures,
  vmelsuresRdy,
  peCmdVld,
  peCmdRdy,
  peBusy,
  peReadAccIdx,
  peReadSubIdx,
  peWriteEn,  
  peWriteAccIdx,
  peWriteSubIdx,
  peWriteData,  
  readAccIdx,
  readSubIdx,
  readData,  
  writeEn,  
  writeAccIdx,
  writeSubIdx,
  writeData  
);

// interface signals
  input  logic                      clk;
  input  logic                      rst_n;
  // 
  input  logic    [`ZVT_LMUL-1:0]   uopVld;
  input  ZVT_RS_t [`ZVT_LMUL-1:0]   uop;
  output logic    [`ZVT_LMUL-1:0]   uopRdy;
  // VME2RVV
  output logic                      res_vme2rvv_vld;
  output PU2ROB_t                   res_vme2rvv;
  input  logic                      res_vme2rvv_rdy;
  // VME2LSU
  output logic                      vmelsuVld;
  output UOP_VME2LSU_t              vmelsu;
  input  logic                      vmelsuRdy;
  // LSU2VME
  input  logic                      vmelsuresVld;
  input  UOP_LSU2VME_t              vmelsures;
  output logic                      vmelsuresRdy;
  // PE array
  output logic    [`ZVT_LMUL-1:0]   peCmdVld;
  input  logic    [`ZVT_LMUL-1:0]   peCmdRdy;
  input  logic                      peBusy;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      peReadAccIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  peReadSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]         peWriteEn;  
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      peWriteAccIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  peWriteSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       peWriteData;  
  // ACC accessing
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      readAccIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  readSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       readData;  
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]         writeEn;  
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      writeAccIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  writeSubIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       writeData;  

// -------------- code start --------------------
  // decode
  logic                 isVme2Lsu, isLsu2Vme, isMv2Rvv, isMv2Vme, isZero; 
  logic [`ZVT_LMUL-1:0] isPe;

  assign isVme2Lsu = uopVld[0] && uop[0].is_lsu &&  uop[0].is_store && vmelsuRdy;
  assign isLsu2Vme = uopVld[0] && uop[0].is_lsu && !uop[0].is_store && vmelsuresVld;

  always_comb begin
    isPe = 'b0;

    for(int i=0; i<`ZVT_LMUL; i++) begin 
      case(uop[i].uop_funct3)
        OPIVV,
        OPFVV: begin
           isPe[i] = uopVld[i] && !uop[i].is_lsu;
        end
      endcase
    end
  end

  always_comb begin
    isMv2Rvv  = 'b0;
    isMv2Vme  = 'b0;
    isZero    = 'b0;

    case(uop[0].uop_funct3)
      OPMVX: begin
        case(uop[0].uop_funct6.ari_funct6)
          VWRXUNARY0: begin
            isZero   = !peBusy && uopVld[0] && !uop[0].is_lsu && (uop[0].vs2==VTZERO);
            isMv2Rvv = !peBusy && uopVld[0] && !uop[0].is_lsu && (uop[0].vs2==VTMVVT);
          end
          VCOMPRESS_VTMVTV: begin
            isMv2Vme = !peBusy && uopVld[0] && !uop[0].is_lsu;
          end
        endcase
      end
    endcase
  end  

  // dispatch to PE
  always_comb begin
    peCmdVld = {(`ZVT_LMUL-1)'(0), isPe[0]};
    for(int i=1; i<`ZVT_LMUL; i++) peCmdVld[i] = peCmdVld[i-1] && isPe[i];
  end  
  
  // Move, LSU, Zero
  logic [$clog2(`NUM_ACC)-1:0]  tile;
  logic                         pattern;
  logic [$clog2(`TE)-1:0]       index;
  logic [`VSTART_WIDTH-1:0]     vstart;
  logic [$clog2(`TE):0]         tm, tn;      
  logic [`TE-1:0]               notvstart;
  logic [`TE-1:0]               tailTmTmp, tailTnTmp;
  logic [`TE-1:0]               nottailTm, nottailTn;
  logic [`TE-1:0]               bodyTm, bodyTn;
  logic [$clog2(`EMUL_MAX)-1:0] uop_index; 
  logic [`VLEN-1:0]             vsrc, vdst;

  logic [`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]                partSubIdx32;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      mvlsuReadAccIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  mvlsuReadSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]         mvlsuWriteEn;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      mvlsuWriteAccIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  mvlsuWriteSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       mvlsuWriteData;  
  
  assign tile      = uop[0].tss.tile;
  assign pattern   = uop[0].tss.pattern;
  assign index     = uop[0].tss.index;
  assign vstart    = uop[0].vstart;
  assign tm        = uop[0].tm[$clog2(`TE):0];
  assign tn        = uop[0].vl;
  assign uop_index = uop[0].uop_index;
  
  // element type
  barrel_shifter #(.DATA_WIDTH(`TE)) 
  u_prestart (.din((`TE)'('1)), .shift_amount(vstart[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(notvstart));
  barrel_shifter #(.DATA_WIDTH(`TE)) 
  u_tailtm   (.din((`TE)'('1)), .shift_amount(tm[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(tailTmTmp));
  barrel_shifter #(.DATA_WIDTH(`TE)) 
  u_tailtn   (.din((`TE)'('1)), .shift_amount(tn[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(tailTnTmp));
  
  assign nottailTm = {`TE{tm[$clog2(`TE)]}} | ~tailTmTmp;
  assign nottailTn = {`TE{tn[$clog2(`TE)]}} | ~tailTnTmp;
  assign bodyTm    = notvstart & nottailTm;
  assign bodyTn    = notvstart & nottailTn;
  
  // source and dst
  always_comb begin
    vsrc        = 'b0;
    res_vme2rvv = 'b0;
    vmelsu      = 'b0;

    case(1'b1)
      isMv2Vme : begin
        vsrc = uop[0].vs2_data;
      end
      isLsu2Vme: begin
        vsrc = vmelsures.w_data;
      end
      isMv2Rvv : begin
      `ifdef TB_SUPPORT
        res_vme2rvv.uop_pc    = uop[0].uop_pc;
      `endif
        res_vme2rvv.rob_entry = uop[0].rob_entry;
        res_vme2rvv.w_data    = vdst;
        res_vme2rvv.w_valid   = 1'b1;
        res_vme2rvv.vsaturate = 'b0;
      `ifdef ZVE32F_ON
        res_vme2rvv.fpexp     = 'b0;
      `endif
      end
      isVme2Lsu: begin
      `ifdef TB_SUPPORT
        vmelsu.uop_pc    = uop[0].uop_pc;
        vmelsu.uop_index = uop_index;
      `endif
        vmelsu.r_data    = vdst;
      end
    endcase
  end

  // Move and LSU access ACC
  always_comb begin
    mvlsuReadAccIdx  = 'b0;
    mvlsuReadSubIdx  = 'b0;
    mvlsuWriteEn     = 'b0;  
    mvlsuWriteAccIdx = 'b0;
    mvlsuWriteSubIdx = 'b0;
    mvlsuWriteData   = 'b0;  

    case(uop[0].eew_mt)
      EEW8: begin
        for(int i=0; i<`TE/4; i++) begin
          if(pattern) begin
            // read
            mvlsuReadAccIdx[0][i] = tile;
            mvlsuReadSubIdx[0][i] = ($clog2(`NUM_SUBTILE))'(index/4) + 
                                    ($clog2(`NUM_SUBTILE))'(i*`TE/4);

            vdst[i*`WORD_WIDTH+:`WORD_WIDTH] = {readData[0][i][({2'b0,index[1:0]}+4'd12)*`BYTE_WIDTH+:`BYTE_WIDTH],
                                                readData[0][i][({2'b0,index[1:0]}+4'd8 )*`BYTE_WIDTH+:`BYTE_WIDTH],
                                                readData[0][i][({2'b0,index[1:0]}+4'd4 )*`BYTE_WIDTH+:`BYTE_WIDTH],
                                                readData[0][i][({2'b0,index[1:0]}      )*`BYTE_WIDTH+:`BYTE_WIDTH]};
            // write
            mvlsuWriteAccIdx[0][i] = mvlsuReadSubIdx[0][i];
            mvlsuWriteSubIdx[0][i] = mvlsuReadSubIdx[0][i];

            {mvlsuWriteEn[0][i][({2'b0,index[1:0]}+4'd12)],
             mvlsuWriteEn[0][i][({2'b0,index[1:0]}+4'd8 )],
             mvlsuWriteEn[0][i][({2'b0,index[1:0]}+4'd4 )],
             mvlsuWriteEn[0][i][({2'b0,index[1:0]}      )]} = {bodyTn[4*i+:4]};

            {mvlsuWriteData[0][i][({2'b0,index[1:0]}+4'd12)*`BYTE_WIDTH+:`BYTE_WIDTH],
             mvlsuWriteData[0][i][({2'b0,index[1:0]}+4'd8 )*`BYTE_WIDTH+:`BYTE_WIDTH],
             mvlsuWriteData[0][i][({2'b0,index[1:0]}+4'd4 )*`BYTE_WIDTH+:`BYTE_WIDTH],
             mvlsuWriteData[0][i][({2'b0,index[1:0]}      )*`BYTE_WIDTH+:`BYTE_WIDTH]} = vsrc[i*`WORD_WIDTH+:`WORD_WIDTH];
          end 
          else begin
            // read
            mvlsuReadAccIdx[0][i] = tile;
            mvlsuReadSubIdx[0][i] = ($clog2(`NUM_SUBTILE))'(index/4*`TE/4) + 
                                    ($clog2(`NUM_SUBTILE))'(i);

            vdst[i*`WORD_WIDTH+:`WORD_WIDTH] = readData[0][i][{index[1:0],2'b0}*`BYTE_WIDTH+:`WORD_WIDTH];
            // write
            mvlsuWriteAccIdx[0][i] = mvlsuReadSubIdx[0][i];
            mvlsuWriteSubIdx[0][i] = mvlsuReadSubIdx[0][i];

            mvlsuWriteEn[0][i][{index[1:0],2'b0}+:4] = bodyTn[4*i+:4];

            mvlsuWriteData[0][i][{index[1:0],2'b0}*`BYTE_WIDTH+:`WORD_WIDTH] = vsrc[i*`WORD_WIDTH+:`WORD_WIDTH];
          end
        end
      end
      EEW16: begin
        for(int i=0; i<`TE/8; i++) begin
          if(pattern) begin
            // read
            mvlsuReadAccIdx[0][i] = {tile[$clog2(`NUM_ACC)-1:1], 1'b0};
            mvlsuReadAccIdx[1][i] = {tile[$clog2(`NUM_ACC)-1:1], 1'b1};
            mvlsuReadSubIdx[0][i] = ($clog2(`NUM_SUBTILE))'(index/4) + 
                                    ($clog2(`NUM_SUBTILE))'({uop_index[0], i[$clog2(`TE/8)-1:0]}*`TE/4);
            mvlsuReadSubIdx[1][i] = mvlsuReadSubIdx[0][i];
                                 

            vdst[i*2*`WORD_WIDTH+:2*`WORD_WIDTH] = {readData[1][i][({index[1],1'b0,index[0],1'b0}+4'd4)*`BYTE_WIDTH+:`HWORD_WIDTH],
                                                    readData[1][i][({index[1],1'b0,index[0],1'b0}     )*`BYTE_WIDTH+:`HWORD_WIDTH],
                                                    readData[0][i][({index[1],1'b0,index[0],1'b0}+4'd4)*`BYTE_WIDTH+:`HWORD_WIDTH],
                                                    readData[0][i][({index[1],1'b0,index[0],1'b0}     )*`BYTE_WIDTH+:`HWORD_WIDTH]};
            // write
            mvlsuWriteAccIdx[0][i] = mvlsuReadSubIdx[0][i];
            mvlsuWriteAccIdx[1][i] = mvlsuReadSubIdx[1][i];
            mvlsuWriteSubIdx[0][i] = mvlsuReadSubIdx[0][i];
            mvlsuWriteSubIdx[1][i] = mvlsuReadSubIdx[1][i];

            {mvlsuWriteEn[1][i][({index[1],1'b0,index[0],1'b0}+4'd4)+:2],
             mvlsuWriteEn[1][i][({index[1],1'b0,index[0],1'b0}     )+:2],
             mvlsuWriteEn[0][i][({index[1],1'b0,index[0],1'b0}+4'd4)+:2],
             mvlsuWriteEn[0][i][({index[1],1'b0,index[0],1'b0}     )+:2]} = {{2{bodyTn[uop_index[0]*`TE/2+4*i+3]}},
                                                                             {2{bodyTn[uop_index[0]*`TE/2+4*i+2]}},
                                                                             {2{bodyTn[uop_index[0]*`TE/2+4*i+1]}},
                                                                             {2{bodyTn[uop_index[0]*`TE/2+4*i  ]}}};

            {mvlsuWriteData[1][i][({index[1],1'b0,index[0],1'b0}+4'd4)*`BYTE_WIDTH+:`HWORD_WIDTH],
             mvlsuWriteData[1][i][({index[1],1'b0,index[0],1'b0}     )*`BYTE_WIDTH+:`HWORD_WIDTH],
             mvlsuWriteData[0][i][({index[1],1'b0,index[0],1'b0}+4'd4)*`BYTE_WIDTH+:`HWORD_WIDTH],
             mvlsuWriteData[0][i][({index[1],1'b0,index[0],1'b0}     )*`BYTE_WIDTH+:`HWORD_WIDTH]} = vsrc[i*2*`WORD_WIDTH+:2*`WORD_WIDTH]; 
          end
          else begin
            // read
            mvlsuReadAccIdx[0][i] = {tile[$clog2(`NUM_ACC)-1:1], index[1]};
            mvlsuReadSubIdx[0][i] = ($clog2(`NUM_SUBTILE))'(index/4*`TE/4) + 
                                    ($clog2(`NUM_SUBTILE))'({uop_index[0], i[$clog2(`TE/8)-1:0]});

            vdst[i*2*`WORD_WIDTH+:2*`WORD_WIDTH] = {readData[0][i][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
                                                   readData[0][i][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH]};
            // write
            mvlsuWriteAccIdx[0][i] = mvlsuReadSubIdx[0][i];
            mvlsuWriteSubIdx[0][i] = mvlsuReadSubIdx[0][i];

            {mvlsuWriteEn[0][i][({1'b0,index[0],2'b0}+4'd4)+:4],
             mvlsuWriteEn[0][i][({1'b0,index[0],2'b0}     )+:4]} = {{2{bodyTn[(uop_index[0]*`TE/2+4*i+3)]}},
                                                                    {2{bodyTn[(uop_index[0]*`TE/2+4*i+2)]}},
                                                                    {2{bodyTn[(uop_index[0]*`TE/2+4*i+1)]}},
                                                                    {2{bodyTn[(uop_index[0]*`TE/2+4*i  )]}}};

            {mvlsuWriteData[0][i][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
             mvlsuWriteData[0][i][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH]} = vsrc[i*2*`WORD_WIDTH+:2*`WORD_WIDTH];
          end
        end      
      end
      default: begin
        for(int i=0; i<`TE/16; i++) begin
          if(pattern) begin
            // read
            mvlsuReadAccIdx[0][i] = {tile[$clog2(`NUM_ACC)-1:2], index[$clog2(`TE/4)], index[1]};
            mvlsuReadAccIdx[1][i] = mvlsuReadAccIdx[0][i];
            mvlsuReadSubIdx[0][i] = ($clog2(`NUM_SUBTILE))'(index/4) + 
                                    ($clog2(`NUM_SUBTILE))'(partSubIdx32[i]*`TE/4); 
            mvlsuReadSubIdx[1][i] = ($clog2(`NUM_SUBTILE))'(index/4) + 
                                    ($clog2(`NUM_SUBTILE))'({partSubIdx32[i][$clog2(`NUM_SUBTILE)-1:1],1'b1}*`TE/4);

            vdst[i*4*`WORD_WIDTH+:4*`WORD_WIDTH] = {readData[1][i][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
                                                    readData[1][i][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH],
                                                    readData[0][i][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
                                                    readData[0][i][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH]};
            // write
            mvlsuWriteAccIdx[0][i] = mvlsuReadSubIdx[0][i];
            mvlsuWriteAccIdx[1][i] = mvlsuReadSubIdx[1][i];
            mvlsuWriteSubIdx[0][i] = mvlsuReadSubIdx[0][i];
            mvlsuWriteSubIdx[1][i] = mvlsuReadSubIdx[1][i];

            {mvlsuWriteEn[1][i][({1'b0,index[0],2'b0}+4'd8)+:4],
             mvlsuWriteEn[1][i][({1'b0,index[0],2'b0}     )+:4],
             mvlsuWriteEn[0][i][({1'b0,index[0],2'b0}+4'd8)+:4],
             mvlsuWriteEn[0][i][({1'b0,index[0],2'b0}     )+:4]} = {{4{bodyTn[uop_index[1:0]*`TE/4+4*i+3]}},
                                                                    {4{bodyTn[uop_index[1:0]*`TE/4+4*i+2]}},
                                                                    {4{bodyTn[uop_index[1:0]*`TE/4+4*i+1]}},
                                                                    {4{bodyTn[uop_index[1:0]*`TE/4+4*i  ]}}};

            {mvlsuWriteData[1][i][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
             mvlsuWriteData[1][i][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH],
             mvlsuWriteData[0][i][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
             mvlsuWriteData[0][i][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH]} = vsrc[i*4*`WORD_WIDTH+:4*`WORD_WIDTH];
          end
          else begin
            // read
            mvlsuReadAccIdx[0][i] = {tile[$clog2(`NUM_ACC)-1:2], index[$clog2(`TE/4)], 1'b0};
            mvlsuReadAccIdx[1][i] = {tile[$clog2(`NUM_ACC)-1:2], index[$clog2(`TE/4)], 1'b1};
            mvlsuReadSubIdx[0][i] = ($clog2(`NUM_SUBTILE))'(index[$clog2(`TE/4)-1:1]*`TE/4) +
                                    partSubIdx32[i];
            mvlsuReadSubIdx[1][i] = mvlsuReadSubIdx[0][i];

            vdst[i*4*`WORD_WIDTH+:4*`WORD_WIDTH] = {readData[1][i][{index[0],3'b0}*`BYTE_WIDTH+:2*`WORD_WIDTH],
                                                   readData[0][i][{index[0],3'b0}*`BYTE_WIDTH+:2*`WORD_WIDTH]};
            // write
            mvlsuWriteAccIdx[0][i] = mvlsuReadSubIdx[0][i];
            mvlsuWriteAccIdx[1][i] = mvlsuReadSubIdx[1][i];
            mvlsuWriteSubIdx[0][i] = mvlsuReadSubIdx[0][i];
            mvlsuWriteSubIdx[1][i] = mvlsuReadSubIdx[1][i];

            {mvlsuWriteEn[1][i][{index[0],3'b0}+:8],
             mvlsuWriteEn[0][i][{index[0],3'b0}+:8]} = {{4{bodyTn[uop_index[1:0]*`TE/4+4*i+3]}},
                                                        {4{bodyTn[uop_index[1:0]*`TE/4+4*i+2]}},
                                                        {4{bodyTn[uop_index[1:0]*`TE/4+4*i+1]}},
                                                        {4{bodyTn[uop_index[1:0]*`TE/4+4*i]  }}};

            {mvlsuWriteData[1][i][{index[0],3'b0}*`BYTE_WIDTH+:2*`WORD_WIDTH],
             mvlsuWriteData[0][i][{index[0],3'b0}*`BYTE_WIDTH+:2*`WORD_WIDTH]} = vsrc[i*4*`WORD_WIDTH+:4*`WORD_WIDTH];
          end
        end
      end
    endcase
  end
  
  generate
    if(`TE==16) begin
      always_comb begin
        for(int i=0; i<`TE/16; i++) begin
          if(pattern) begin
            partSubIdx32[i] = ($clog2(`NUM_SUBTILE))'({uop_index[0], 1'b0});
          end
          else begin
            partSubIdx32[i] = ($clog2(`NUM_SUBTILE))'(uop_index[1:0]); 
          end
        end
      end
    end
    else begin
      always_comb begin
        for(int i=0; i<`TE/16; i++) begin
          if(pattern) begin
            partSubIdx32[i] = ($clog2(`NUM_SUBTILE))'({uop_index[0], i[$clog2(`TE/16)-1:0], 1'b0});
          end
          else begin
            partSubIdx32[i] = ($clog2(`NUM_SUBTILE))'({uop_index[1:0], i[$clog2(`TE/16)-1:0]});
          end
        end
      end
    end
  endgenerate

  // Zero
  logic [$clog2(`PROCESS_DELAY)-1:0]  cnt, cntMax;
  logic                               cntEn, cntCr;
  
  assign cntMax = `PROCESS_DELAY - 1;
  assign cntCr  = cnt==cntMax;
  assign cntEn  = isZero;

  cdffr #(.T(logic [$clog2(`PROCESS_DELAY)-1:0]))
  counter (.q(cnt), .clk(clk), .rst_n(rst_n), .e(cntEn), .c(cntCr), .d(cnt+($clog2(`PROCESS_DELAY))'('d1)));

  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]         zeroWriteEn;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      zeroWriteAccIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  zeroWriteSubIdx;

  always_comb begin
    zeroWriteEn     = 'b0;  
    zeroWriteAccIdx = 'b0;
    zeroWriteSubIdx = 'b0;

    case(uop[0].eew_mt)
      EEW8: begin
        for(int i=0; i<`TE/4*`COMPRATIO; i++) begin
          for(int j=0; j<`TE/4/4; j++) begin
            zeroWriteAccIdx[0][`TE/4/4*i+j] = tile;
            zeroWriteAccIdx[1][`TE/4/4*i+j] = tile;
            zeroWriteAccIdx[2][`TE/4/4*i+j] = tile;
            zeroWriteAccIdx[3][`TE/4/4*i+j] = tile;
            
            zeroWriteSubIdx[0][`TE/4/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+4*j);
            zeroWriteSubIdx[1][`TE/4/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+4*j+'d1);
            zeroWriteSubIdx[2][`TE/4/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+4*j+'d2);
            zeroWriteSubIdx[3][`TE/4/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+4*j+'d3);
            
            zeroWriteEn[0][`TE/4/4*i+j] = {4{bodyTm[(16*j   )+:4]}} & {{4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}};
            zeroWriteEn[1][`TE/4/4*i+j] = {4{bodyTm[(16*j+4 )+:4]}} & {{4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}};
            zeroWriteEn[2][`TE/4/4*i+j] = {4{bodyTm[(16*j+8 )+:4]}} & {{4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}};
            zeroWriteEn[3][`TE/4/4*i+j] = {4{bodyTm[(16*j+12)+:4]}} & {{4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                                                       {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}};
          end
        end
      end
      EEW16: begin
        for(int i=0; i<`TE/4*`COMPRATIO; i++) begin
          for(int j=0; j<`TE/4/2; j++) begin
            zeroWriteAccIdx[0][`TE/4/2*i+j] = {tile[3:1], 1'b0};
            zeroWriteAccIdx[1][`TE/4/2*i+j] = {tile[3:1], 1'b1};
            zeroWriteAccIdx[2][`TE/4/2*i+j] = {tile[3:1], 1'b0};
            zeroWriteAccIdx[3][`TE/4/2*i+j] = {tile[3:1], 1'b1};
            
            zeroWriteSubIdx[0][`TE/4/2*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+2*j);
            zeroWriteSubIdx[1][`TE/4/2*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+2*j);
            zeroWriteSubIdx[2][`TE/4/2*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+2*j+'d1);
            zeroWriteSubIdx[3][`TE/4/2*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+2*j+'d1);
            
            zeroWriteEn[0][`TE/4/2*i+j] = {{2{bodyTm[(8*j  )+3]}}, 
                                           {2{bodyTm[(8*j  )+2]}},                         
                                           {2{bodyTm[(8*j  )+3]}},                         
                                           {2{bodyTm[(8*j  )+2]}},                         
                                           {2{bodyTm[(8*j  )+1]}},                         
                                           {2{bodyTm[(8*j  )+0]}},                         
                                           {2{bodyTm[(8*j  )+1]}},                         
                                           {2{bodyTm[(8*j  )+0]}}} & {{4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}};
            zeroWriteEn[1][`TE/4/2*i+j] = {{2{bodyTm[(8*j  )+3]}}, 
                                           {2{bodyTm[(8*j  )+2]}},                         
                                           {2{bodyTm[(8*j  )+3]}},                         
                                           {2{bodyTm[(8*j  )+2]}},                         
                                           {2{bodyTm[(8*j  )+1]}},                         
                                           {2{bodyTm[(8*j  )+0]}},                         
                                           {2{bodyTm[(8*j  )+1]}},                         
                                           {2{bodyTm[(8*j  )+0]}}} & {{4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}}};
            zeroWriteEn[2][`TE/4/2*i+j] = {{2{bodyTm[(8*j+4)+3]}}, 
                                           {2{bodyTm[(8*j+4)+2]}},                         
                                           {2{bodyTm[(8*j+4)+3]}},                         
                                           {2{bodyTm[(8*j+4)+2]}},                         
                                           {2{bodyTm[(8*j+4)+1]}},                         
                                           {2{bodyTm[(8*j+4)+0]}},                         
                                           {2{bodyTm[(8*j+4)+1]}},                         
                                           {2{bodyTm[(8*j+4)+0]}}} & {{4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}};
            zeroWriteEn[3][`TE/4/2*i+j] = {{2{bodyTm[(8*j+4)+3]}}, 
                                           {2{bodyTm[(8*j+4)+2]}},                         
                                           {2{bodyTm[(8*j+4)+3]}},                         
                                           {2{bodyTm[(8*j+4)+2]}},                         
                                           {2{bodyTm[(8*j+4)+1]}},                         
                                           {2{bodyTm[(8*j+4)+0]}},                         
                                           {2{bodyTm[(8*j+4)+1]}},                         
                                           {2{bodyTm[(8*j+4)+0]}}} & {{4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                                                      {4{bodyTn[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}}};
          end
        end
      end
      default: begin  // EEW32
        for(int i=0; i<`TE/4*`COMPRATIO; i++) begin
          for(int j=0; j<`TE/4; j++) begin
            zeroWriteAccIdx[0][`TE/4*i+j] = {tile[3:2], 2'd0};
            zeroWriteAccIdx[1][`TE/4*i+j] = {tile[3:2], 2'd1};
            zeroWriteAccIdx[2][`TE/4*i+j] = {tile[3:2], 2'd2};
            zeroWriteAccIdx[3][`TE/4*i+j] = {tile[3:2], 2'd3};
            
            zeroWriteSubIdx[0][`TE/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+j);
            zeroWriteSubIdx[1][`TE/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+j);
            zeroWriteSubIdx[2][`TE/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+j);
            zeroWriteSubIdx[3][`TE/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+j);
            
            zeroWriteEn[0][`TE/4*i+j] = {{4{bodyTm[(4*j  )+1]}}, 
                                         {4{bodyTm[(4*j  )+0]}},                         
                                         {4{bodyTm[(4*j  )+1]}},                         
                                         {4{bodyTm[(4*j  )+0]}}} & {{8{bodyTn[(`TE/4*`COMPRATIO)*2*cnt+2*i+1]}},
                                                                    {8{bodyTn[(`TE/4*`COMPRATIO)*2*cnt+2*i  ]}}};
            zeroWriteEn[1][`TE/4*i+j] = {{4{bodyTm[(4*j+2)+1]}}, 
                                         {4{bodyTm[(4*j+2)+0]}},                         
                                         {4{bodyTm[(4*j+2)+1]}},                         
                                         {4{bodyTm[(4*j+2)+0]}}} & {{8{bodyTn[(`TE/4*`COMPRATIO)*2*cnt+2*i+1]}},
                                                                    {8{bodyTn[(`TE/4*`COMPRATIO)*2*cnt+2*i  ]}}};
            zeroWriteEn[2][`TE/4*i+j] = {{4{bodyTm[(4*j  )+1]}}, 
                                         {4{bodyTm[(4*j  )+0]}},                         
                                         {4{bodyTm[(4*j  )+1]}},                         
                                         {4{bodyTm[(4*j  )+0]}}} & {{8{bodyTn[`TE/2+(`TE/4*`COMPRATIO)*2*cnt+2*i+1]}},
                                                                    {8{bodyTn[`TE/2+(`TE/4*`COMPRATIO)*2*cnt+2*i  ]}}};
            zeroWriteEn[3][`TE/4*i+j] = {{4{bodyTm[(4*j+2)+1]}}, 
                                         {4{bodyTm[(4*j+2)+0]}},                         
                                         {4{bodyTm[(4*j+2)+1]}},                         
                                         {4{bodyTm[(4*j+2)+0]}}} & {{8{bodyTn[`TE/2+(`TE/4*`COMPRATIO)*2*cnt+2*i+1]}},
                                                                    {8{bodyTn[`TE/2+(`TE/4*`COMPRATIO)*2*cnt+2*i  ]}}};
          end
        end      
      end
    endcase
  end

  // uopRdy
  always_comb begin
    uopRdy = 'b0;

    case(1'b1)
      isVme2Lsu: begin
        vmelsuVld       = 1'b1;
        uopRdy[0]       = 1'b1;
      end
      isLsu2Vme: begin
        uopRdy[0]       = 1'b1;
        vmelsuresRdy    = 1'b1;
      end
      isMv2Rvv: begin
        res_vme2rvv_vld = 1'b1;
        uopRdy[0]       = res_vme2rvv_rdy; 
      end
      isMv2Vme: begin
        uopRdy[0] = 1'b1;
      end
      isZero: begin
        uopRdy[0] = cntCr;
      end
      default: begin
        uopRdy = peCmdRdy;
      end
    endcase
  end


  // ACC accessing
  always_comb begin
    case(1'b1)
      isMv2Rvv,
      isMv2Vme,
      isLsu2Vme,
      isVme2Lsu: begin
        readAccIdx  = mvlsuReadAccIdx;
        readSubIdx  = mvlsuReadSubIdx;
        writeEn     = mvlsuWriteEn;  
        writeAccIdx = mvlsuWriteAccIdx;
        writeSubIdx = mvlsuWriteSubIdx;
        writeData   = mvlsuWriteData;
      end
      isZero: begin  
        readAccIdx  = peReadAccIdx; // ignore it.
        readSubIdx  = peReadSubIdx; // ignore it.
        writeEn     = zeroWriteEn;  
        writeAccIdx = zeroWriteAccIdx;
        writeSubIdx = zeroWriteSubIdx;
        writeData   = 'b0;
      end
      default: begin
        readAccIdx  = peReadAccIdx;
        readSubIdx  = peReadSubIdx;
        writeEn     = peWriteEn;  
        writeAccIdx = peWriteAccIdx;
        writeSubIdx = peWriteSubIdx;
        writeData   = peWriteData;
      end
    endcase
  end

endmodule

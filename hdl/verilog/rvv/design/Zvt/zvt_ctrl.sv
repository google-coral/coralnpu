`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_ctrl (
  clk,
  rst_n,
  uopVld,
  uop,
  uopRdy,
  resVme2rvvVld,
  resVme2rvv,
  resVme2rvvRdy,
  vmelsuVld,
  vmelsu,
  vmelsuRdy,
  vmelsuresVld,
  vmelsures,
  vmelsuresRdy,
  peCmdVld,
  peCmdRdy,
  peBusy,
  peReadMtIdx,
  peReadSubIdx,
`ifdef TB_SUPPORT
  peReadPc,
  peWritePc,
`endif
  peWriteEn,  
  peWriteMtIdx,
  peWriteSubIdx,
  peWriteData,  
  readMtIdx,
  readSubIdx,
  readData,  
  writeEn,  
  writeMtIdx,
  writeSubIdx,
  writeData,  
  rtCmdVld,
  rtCmd,
  rtCmdRdy,
  miscRtVld
`ifdef RVVI_ON
  ,miscRtMtIdx
`endif
);

// interface signals
  input  logic                      clk;
  input  logic                      rst_n;
  // 
  input  logic    [`ZVT_LMUL-1:0]   uopVld;
  input  ZVT_RS_t [`ZVT_LMUL-1:0]   uop;
  output logic    [`ZVT_LMUL-1:0]   uopRdy;
  // VME2RVV
  output logic                      resVme2rvvVld;
  output PU2ROB_t                   resVme2rvv;
  input  logic                      resVme2rvvRdy;
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
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      peReadMtIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] peReadSubIdx;
`ifdef TB_SUPPORT
  input  logic [`NUM_BLK-1:0][`PC_WIDTH-1:0]                              peReadPc;
  input  logic [`NUM_BLK-1:0][`PC_WIDTH-1:0]                              peWritePc;
`endif
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        peWriteEn;  
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      peWriteMtIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] peWriteSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      peWriteData;  
  // MT accessing
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      readMtIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] readSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      readData;  
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        writeEn;  
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      writeMtIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] writeSubIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      writeData;  
  // Retire Cmd 
  output logic                      rtCmdVld;
  output VME_RTCMD_t                rtCmd;
  input  logic                      rtCmdRdy;
  // LSU/MV/Zero retiring informaiton
  output logic                      miscRtVld;
`ifdef RVVI_ON
  output logic [$clog2(`NUM_MT)-1:0]  miscRtMtIdx;
`endif

// -------------- code start --------------------
  // decode
  logic                 isVme2Lsu, isLsu2Vme, isMv2Rvv, isMv2Vme, isZero; 
  logic [`ZVT_LMUL-1:0] isPe;

  assign isVme2Lsu = uopVld[0] && uop[0].is_lsu &&  uop[0].is_store && vmelsuRdy && (!uop[0].first_uop_valid || rtCmdRdy);
  assign isLsu2Vme = uopVld[0] && uop[0].is_lsu && !uop[0].is_store && vmelsuresVld && (!uop[0].first_uop_valid || rtCmdRdy);

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
            isZero   = !peBusy && uopVld[0] && !uop[0].is_lsu && (uop[0].vs2==VTZERO) && rtCmdRdy;
            isMv2Rvv = !peBusy && uopVld[0] && !uop[0].is_lsu && (uop[0].vs2==VTMVVT);
          end
          VCOMPRESS_VTMVTV: begin
            isMv2Vme = !peBusy && uopVld[0] && !uop[0].is_lsu && (!uop[0].first_uop_valid || rtCmdRdy);
          end
        endcase
      end
    endcase
  end  

  // dispatch to PE
  always_comb begin
    peCmdVld = {(`ZVT_LMUL-1)'(0), isPe[0] && rtCmdRdy};
    for(int i=1; i<`ZVT_LMUL; i++) peCmdVld[i] = peCmdVld[i-1] && isPe[i];
  end  
  
  // Move, LSU, Zero
  logic [$clog2(`NUM_MT)-1:0]   tile;
  logic                         pattern;
  logic [$clog2(`TE)-1:0]       index;
  logic [`VSTART_WIDTH-1:0]     vstart;
  logic [$clog2(`TE):0]         tm, tn;      
  logic [`TE-1:0]               notVstart;
  logic [`TE-1:0]               tailTmTmp, tailTnTmp;
  logic [`TE-1:0]               notTailTm, notTailTn;
  logic [`TE-1:0]               bodyTm, bodyTn;
  logic [$clog2(`EMUL_MAX)-1:0] uop_index; 
  logic [`VLEN-1:0]             vsrc, vdst;

  logic [`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]               partSubIdx32;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      mvlsuReadMtIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] mvlsuReadSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        mvlsuWriteEn;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      mvlsuWriteMtIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] mvlsuWriteSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      mvlsuWriteData;  
  
  // vtzero encodes its destination tile in rd (dst_index[4:1]); TSS ops
  // encode it in rs1 (tss.tile).
  assign tile      = isZero ? uop[0].dst_index[4:1] : uop[0].tss.tile;
  assign pattern   = uop[0].tss.pattern;
  assign index     = uop[0].tss.index;
  assign vstart    = uop[0].vstart;
  assign tm        = uop[0].tm[$clog2(`TE):0];
  assign tn        = uop[0].vl;
  assign uop_index = uop[0].uop_index;
  
  // element type
  barrel_shifter #(.DATA_WIDTH(`TE)) 
  u_prestart (.din((`TE)'('1)), .shift_amount(vstart[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(notVstart));
  barrel_shifter #(.DATA_WIDTH(`TE)) 
  u_tailtm   (.din((`TE)'('1)), .shift_amount(tm[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(tailTmTmp));
  barrel_shifter #(.DATA_WIDTH(`TE)) 
  u_tailtn   (.din((`TE)'('1)), .shift_amount(tn[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(tailTnTmp));
  
  assign notTailTm = {`TE{tm[$clog2(`TE)]}} | ~tailTmTmp;
  assign notTailTn = {`TE{tn[$clog2(`TE)]}} | ~tailTnTmp;
  assign bodyTm    = notVstart & notTailTm;
  assign bodyTn    = notVstart & notTailTn;
  
  // source and dst
  always_comb begin
    vsrc       = 'b0;
    resVme2rvv = 'b0;
    vmelsu     = 'b0;

    case(1'b1)
      isMv2Vme : begin
        vsrc = uop[0].vs2_data;
      end
      isLsu2Vme: begin
        vsrc = vmelsures.w_data;
      end
      isMv2Rvv : begin
      `ifdef TB_SUPPORT
        resVme2rvv.uop_pc    = uop[0].uop_pc;
      `endif
        resVme2rvv.rob_entry = uop[0].rob_entry;
        resVme2rvv.w_data    = vdst;
        resVme2rvv.w_valid   = 1'b1;
        resVme2rvv.vsaturate = 'b0;
      `ifdef ZVE32F_ON
        resVme2rvv.fpexp     = 'b0;
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

  // Move and LSU access MT
  assign mvlsuWriteMtIdx  = mvlsuReadMtIdx;
    
  always_comb begin
    mvlsuReadMtIdx   = 'b0;
    mvlsuReadSubIdx  = 'b0;
    mvlsuWriteEn     = 'b0;
    mvlsuWriteSubIdx = 'b0;
    mvlsuWriteData   = 'b0;

    case(uop[0].eew_mt)
      EEW8: begin
        for(int i=0; i<`TE/4; i++) begin
          if(pattern) begin
            // read
            mvlsuReadMtIdx[0][i]  = tile;
            mvlsuReadSubIdx[0][i] = ($clog2(`NUM_SUBTILE))'(index/4) + 
                                    ($clog2(`NUM_SUBTILE))'(i*`TE/4);

            vdst[i*`WORD_WIDTH+:`WORD_WIDTH] = {readData[0][i][({2'b0,index[1:0]}+4'd12)*`BYTE_WIDTH+:`BYTE_WIDTH],
                                                readData[0][i][({2'b0,index[1:0]}+4'd8 )*`BYTE_WIDTH+:`BYTE_WIDTH],
                                                readData[0][i][({2'b0,index[1:0]}+4'd4 )*`BYTE_WIDTH+:`BYTE_WIDTH],
                                                readData[0][i][({2'b0,index[1:0]}      )*`BYTE_WIDTH+:`BYTE_WIDTH]};
            // write
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
            mvlsuReadMtIdx[0][i]  = tile;
            mvlsuReadSubIdx[0][i] = ($clog2(`NUM_SUBTILE))'(index/4*`TE/4) + 
                                    ($clog2(`NUM_SUBTILE))'(i);

            vdst[i*`WORD_WIDTH+:`WORD_WIDTH] = readData[0][i][{index[1:0],2'b0}*`BYTE_WIDTH+:`WORD_WIDTH];
            // write
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
            mvlsuReadMtIdx[0][2*i  ]  = {tile[$clog2(`NUM_MT)-1:1], 1'b0};
            mvlsuReadMtIdx[0][2*i+1]  = {tile[$clog2(`NUM_MT)-1:1], 1'b1};
            mvlsuReadSubIdx[0][2*i  ] = ($clog2(`NUM_SUBTILE))'(index/4) + 
                                        ($clog2(`NUM_SUBTILE))'({uop_index[0], i[$clog2(`TE/8)-1:0]}*`TE/4);
            mvlsuReadSubIdx[0][2*i+1] = mvlsuReadSubIdx[0][2*i];
                                 

            vdst[i*2*`WORD_WIDTH+:2*`WORD_WIDTH] = {readData[0][2*i+1][({index[1],1'b0,index[0],1'b0}+4'd4)*`BYTE_WIDTH+:`HWORD_WIDTH],
                                                    readData[0][2*i+1][({index[1],1'b0,index[0],1'b0}     )*`BYTE_WIDTH+:`HWORD_WIDTH],
                                                    readData[0][2*i  ][({index[1],1'b0,index[0],1'b0}+4'd4)*`BYTE_WIDTH+:`HWORD_WIDTH],
                                                    readData[0][2*i  ][({index[1],1'b0,index[0],1'b0}     )*`BYTE_WIDTH+:`HWORD_WIDTH]};
            // write
            mvlsuWriteSubIdx[0][2*i  ] = mvlsuReadSubIdx[0][2*i];
            mvlsuWriteSubIdx[0][2*i+1] = mvlsuReadSubIdx[0][2*i+1];

            {mvlsuWriteEn[0][2*i+1][({index[1],1'b0,index[0],1'b0}+4'd4)+:2],
             mvlsuWriteEn[0][2*i+1][({index[1],1'b0,index[0],1'b0}     )+:2],
             mvlsuWriteEn[0][2*i  ][({index[1],1'b0,index[0],1'b0}+4'd4)+:2],
             mvlsuWriteEn[0][2*i  ][({index[1],1'b0,index[0],1'b0}     )+:2]} = {{2{bodyTn[uop_index[0]*`TE/2+4*i+3]}},
                                                                                 {2{bodyTn[uop_index[0]*`TE/2+4*i+2]}},
                                                                                 {2{bodyTn[uop_index[0]*`TE/2+4*i+1]}},
                                                                                 {2{bodyTn[uop_index[0]*`TE/2+4*i  ]}}};

            {mvlsuWriteData[0][2*i+1][({index[1],1'b0,index[0],1'b0}+4'd4)*`BYTE_WIDTH+:`HWORD_WIDTH],
             mvlsuWriteData[0][2*i+1][({index[1],1'b0,index[0],1'b0}     )*`BYTE_WIDTH+:`HWORD_WIDTH],
             mvlsuWriteData[0][2*i  ][({index[1],1'b0,index[0],1'b0}+4'd4)*`BYTE_WIDTH+:`HWORD_WIDTH],
             mvlsuWriteData[0][2*i  ][({index[1],1'b0,index[0],1'b0}     )*`BYTE_WIDTH+:`HWORD_WIDTH]} = vsrc[i*2*`WORD_WIDTH+:2*`WORD_WIDTH]; 
          end
          else begin
            // read
            mvlsuReadMtIdx[0][i]  = {tile[$clog2(`NUM_MT)-1:1], index[1]};
            mvlsuReadSubIdx[0][i] = ($clog2(`NUM_SUBTILE))'(index/4*`TE/4) + 
                                    ($clog2(`NUM_SUBTILE))'({uop_index[0], i[$clog2(`TE/8)-1:0]});

            vdst[i*2*`WORD_WIDTH+:2*`WORD_WIDTH] = {readData[0][i][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
                                                    readData[0][i][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH]};
            // write
            mvlsuWriteSubIdx[0][i] = mvlsuReadSubIdx[0][i];

            {mvlsuWriteEn[0][i][({1'b0,index[0],2'b0}+4'd8)+:4],
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
            mvlsuReadMtIdx[0][2*i  ]  = {tile[$clog2(`NUM_MT)-1:2], uop_index[1], index[1]};
            mvlsuReadMtIdx[0][2*i+1]  = mvlsuReadMtIdx[0][i];
            mvlsuReadSubIdx[0][2*i  ] = ($clog2(`NUM_SUBTILE))'(index/4) + 
                                        ($clog2(`NUM_SUBTILE))'(partSubIdx32[i]*`TE/4); 
            mvlsuReadSubIdx[0][2*i+1] = ($clog2(`NUM_SUBTILE))'(index/4) + 
                                        ($clog2(`NUM_SUBTILE))'({partSubIdx32[i][$clog2(`NUM_SUBTILE)-1:1],1'b1}*`TE/4);

            vdst[i*4*`WORD_WIDTH+:4*`WORD_WIDTH] = {readData[0][2*i+1][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
                                                    readData[0][2*i+1][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH],
                                                    readData[0][2*i  ][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
                                                    readData[0][2*i  ][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH]};
            // write
            mvlsuWriteSubIdx[0][2*i  ] = mvlsuReadSubIdx[0][2*i  ];
            mvlsuWriteSubIdx[0][2*i+1] = mvlsuReadSubIdx[0][2*i+1];

            {mvlsuWriteEn[0][2*i+1][({1'b0,index[0],2'b0}+4'd8)+:4],
             mvlsuWriteEn[0][2*i+1][({1'b0,index[0],2'b0}     )+:4],
             mvlsuWriteEn[0][2*i  ][({1'b0,index[0],2'b0}+4'd8)+:4],
             mvlsuWriteEn[0][2*i  ][({1'b0,index[0],2'b0}     )+:4]} = {{4{bodyTn[uop_index[1:0]*`TE/4+4*i+3]}},
                                                                        {4{bodyTn[uop_index[1:0]*`TE/4+4*i+2]}},
                                                                        {4{bodyTn[uop_index[1:0]*`TE/4+4*i+1]}},
                                                                        {4{bodyTn[uop_index[1:0]*`TE/4+4*i  ]}}};

            {mvlsuWriteData[0][2*i+1][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
             mvlsuWriteData[0][2*i+1][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH],
             mvlsuWriteData[0][2*i  ][({1'b0,index[0],2'b0}+4'd8)*`BYTE_WIDTH+:`WORD_WIDTH],
             mvlsuWriteData[0][2*i  ][({1'b0,index[0],2'b0}     )*`BYTE_WIDTH+:`WORD_WIDTH]} = vsrc[i*4*`WORD_WIDTH+:4*`WORD_WIDTH];
          end
          else begin
            // read
            // TEW=32 punning: ptile = tile + 2*(row/(TE/2)) + col[1], and the
            // subtile row is (row/2)%(TE/4) -- i.e. the partition bit is
            // row's MSB (index[log2(TE/2)]), with the bits below it (down to
            // bit 1) selecting the subtile row. This matches the PE array's
            // addressing (BLKID[1] carries row/(TE/2), readMtId carries
            // (row/2)%(TE/4)).
            mvlsuReadMtIdx[0][2*i  ]  = {tile[$clog2(`NUM_MT)-1:2], index[$clog2(`TE/2)], 1'b0};
            mvlsuReadMtIdx[0][2*i+1]  = {tile[$clog2(`NUM_MT)-1:2], index[$clog2(`TE/2)], 1'b1};
            mvlsuReadSubIdx[0][2*i  ] = ($clog2(`NUM_SUBTILE))'(index[$clog2(`TE/2)-1:1]*`TE/4) +
                                        partSubIdx32[i];
            mvlsuReadSubIdx[0][2*i+1] = mvlsuReadSubIdx[0][2*i];

            vdst[i*4*`WORD_WIDTH+:4*`WORD_WIDTH] = {readData[0][2*i+1][{index[0],3'b0}*`BYTE_WIDTH+:2*`WORD_WIDTH],
                                                    readData[0][2*i  ][{index[0],3'b0}*`BYTE_WIDTH+:2*`WORD_WIDTH]};
            // write
            mvlsuWriteSubIdx[0][2*i  ] = mvlsuReadSubIdx[0][2*i];
            mvlsuWriteSubIdx[0][2*i+1] = mvlsuReadSubIdx[0][2*i+1];

            {mvlsuWriteEn[0][2*i+1][{index[0],3'b0}+:8],
             mvlsuWriteEn[0][2*i  ][{index[0],3'b0}+:8]} = {{4{bodyTn[uop_index[1:0]*`TE/4+4*i+3]}},
                                                            {4{bodyTn[uop_index[1:0]*`TE/4+4*i+2]}},
                                                            {4{bodyTn[uop_index[1:0]*`TE/4+4*i+1]}},
                                                            {4{bodyTn[uop_index[1:0]*`TE/4+4*i]  }}};

            {mvlsuWriteData[0][2*i+1][{index[0],3'b0}*`BYTE_WIDTH+:2*`WORD_WIDTH],
             mvlsuWriteData[0][2*i  ][{index[0],3'b0}*`BYTE_WIDTH+:2*`WORD_WIDTH]} = vsrc[i*4*`WORD_WIDTH+:4*`WORD_WIDTH];
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

  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        zeroWriteEn;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      zeroWriteMtIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] zeroWriteSubIdx;

  always_comb begin
    zeroWriteEn     = 'b0;  
    zeroWriteMtIdx = 'b0;
    zeroWriteSubIdx = 'b0;

    case(uop[0].eew_mt)
      EEW8: begin
        for(int i=0; i<`TE/4*`COMPRATIO; i++) begin
          for(int j=0; j<`TE/4/4; j++) begin
            zeroWriteMtIdx[0][`TE/4/4*i+j] = tile;
            zeroWriteMtIdx[1][`TE/4/4*i+j] = tile;
            zeroWriteMtIdx[2][`TE/4/4*i+j] = tile;
            zeroWriteMtIdx[3][`TE/4/4*i+j] = tile;
            
            zeroWriteSubIdx[0][`TE/4/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+4*j);
            zeroWriteSubIdx[1][`TE/4/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+4*j+'d1);
            zeroWriteSubIdx[2][`TE/4/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+4*j+'d2);
            zeroWriteSubIdx[3][`TE/4/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+4*j+'d3);
            
            zeroWriteEn[0][`TE/4/4*i+j] = {{4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}} & {4{bodyTn[(16*j   )+:4]}}; 
            zeroWriteEn[1][`TE/4/4*i+j] = {{4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},                             
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},                             
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},                             
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}} & {4{bodyTn[(16*j+4 )+:4]}};                    zeroWriteEn[2][`TE/4/4*i+j] = {{4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},                             
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},                             
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},                             
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}} & {4{bodyTn[(16*j+8 )+:4]}};
            zeroWriteEn[3][`TE/4/4*i+j] = {{4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},                             
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},                             
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},                             
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}} & {4{bodyTn[(16*j+12)+:4]}};
          end                                                                                                       
        end                                                                                                         
      end                                                                                                           
      EEW16: begin
        for(int i=0; i<`TE/4*`COMPRATIO; i++) begin
          for(int j=0; j<`TE/4/2; j++) begin
            zeroWriteMtIdx[0][`TE/4/2*i+j] = {tile[3:1], 1'b0};
            zeroWriteMtIdx[1][`TE/4/2*i+j] = {tile[3:1], 1'b0};
            zeroWriteMtIdx[2][`TE/4/2*i+j] = {tile[3:1], 1'b1};
            zeroWriteMtIdx[3][`TE/4/2*i+j] = {tile[3:1], 1'b1};
            
            zeroWriteSubIdx[0][`TE/4/2*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+2*j);
            zeroWriteSubIdx[1][`TE/4/2*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+2*j+'d1);
            zeroWriteSubIdx[2][`TE/4/2*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+2*j);
            zeroWriteSubIdx[3][`TE/4/2*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+2*j+'d1);
            
            zeroWriteEn[0][`TE/4/2*i+j] = {{4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}} & {{2{bodyTn[(8*j  )+3]}}, 
                                                                                           {2{bodyTn[(8*j  )+2]}},
                                                                                           {2{bodyTn[(8*j  )+3]}},
                                                                                           {2{bodyTn[(8*j  )+2]}},
                                                                                           {2{bodyTn[(8*j  )+1]}},
                                                                                           {2{bodyTn[(8*j  )+0]}},
                                                                                           {2{bodyTn[(8*j  )+1]}},
                                                                                           {2{bodyTn[(8*j  )+0]}}};
            zeroWriteEn[1][`TE/4/2*i+j] = {{4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+1]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i  ]}}} & {{2{bodyTn[(8*j+4)+3]}}, 
                                                                                           {2{bodyTn[(8*j+4)+2]}},
                                                                                           {2{bodyTn[(8*j+4)+3]}},
                                                                                           {2{bodyTn[(8*j+4)+2]}},
                                                                                           {2{bodyTn[(8*j+4)+1]}},
                                                                                           {2{bodyTn[(8*j+4)+0]}},
                                                                                           {2{bodyTn[(8*j+4)+1]}},
                                                                                           {2{bodyTn[(8*j+4)+0]}}};
            zeroWriteEn[2][`TE/4/2*i+j] = {{4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}}} & {{2{bodyTn[(8*j  )+3]}}, 
                                                                                           {2{bodyTn[(8*j  )+2]}},
                                                                                           {2{bodyTn[(8*j  )+3]}},
                                                                                           {2{bodyTn[(8*j  )+2]}},
                                                                                           {2{bodyTn[(8*j  )+1]}},
                                                                                           {2{bodyTn[(8*j  )+0]}},
                                                                                           {2{bodyTn[(8*j  )+1]}},
                                                                                           {2{bodyTn[(8*j  )+0]}}};
            zeroWriteEn[3][`TE/4/2*i+j] = {{4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+3]}},
                                           {4{bodyTm[(`TE/4*`COMPRATIO)*4*cnt+4*i+2]}}} & {{2{bodyTn[(8*j+4)+3]}}, 
                                                                                           {2{bodyTn[(8*j+4)+2]}},
                                                                                           {2{bodyTn[(8*j+4)+3]}},
                                                                                           {2{bodyTn[(8*j+4)+2]}},
                                                                                           {2{bodyTn[(8*j+4)+1]}},
                                                                                           {2{bodyTn[(8*j+4)+0]}},
                                                                                           {2{bodyTn[(8*j+4)+1]}},
                                                                                           {2{bodyTn[(8*j+4)+0]}}};
          end
        end
      end
      default: begin  // EEW32
        for(int i=0; i<`TE/4*`COMPRATIO; i++) begin
          for(int j=0; j<`TE/2/2; j++) begin
            zeroWriteMtIdx[0][`TE/4*i+j] = {tile[3:2], 2'd0};
            zeroWriteMtIdx[1][`TE/4*i+j] = {tile[3:2], 2'd1};
            zeroWriteMtIdx[2][`TE/4*i+j] = {tile[3:2], 2'd2};
            zeroWriteMtIdx[3][`TE/4*i+j] = {tile[3:2], 2'd3};
            
            zeroWriteSubIdx[0][`TE/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+j);
            zeroWriteSubIdx[1][`TE/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+j);
            zeroWriteSubIdx[2][`TE/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+j);
            zeroWriteSubIdx[3][`TE/4*i+j] = (`SUBTILE_SIZE)'((`TE/4)*(`TE/4*`COMPRATIO)*cnt+`TE/4*i+j);
            
            zeroWriteEn[0][`TE/4*i+j] = {{8{bodyTm[(`TE/4*`COMPRATIO)*2*cnt+2*i+1]}},
                                         {8{bodyTm[(`TE/4*`COMPRATIO)*2*cnt+2*i  ]}}} & {{4{bodyTn[(4*j  )+1]}}, 
                                                                                         {4{bodyTn[(4*j  )+0]}},
                                                                                         {4{bodyTn[(4*j  )+1]}},
                                                                                         {4{bodyTn[(4*j  )+0]}}};
            zeroWriteEn[1][`TE/4*i+j] = {{8{bodyTm[(`TE/4*`COMPRATIO)*2*cnt+2*i+1]}},
                                         {8{bodyTm[(`TE/4*`COMPRATIO)*2*cnt+2*i  ]}}} & {{4{bodyTn[(4*j+2)+1]}}, 
                                                                                         {4{bodyTn[(4*j+2)+0]}},
                                                                                         {4{bodyTn[(4*j+2)+1]}},
                                                                                         {4{bodyTn[(4*j+2)+0]}}};
            zeroWriteEn[2][`TE/4*i+j] = {{8{bodyTm[`TE/2+(`TE/4*`COMPRATIO)*2*cnt+2*i+1]}},
                                         {8{bodyTm[`TE/2+(`TE/4*`COMPRATIO)*2*cnt+2*i  ]}}} & {{4{bodyTn[(4*j  )+1]}}, 
                                                                                               {4{bodyTn[(4*j  )+0]}},
                                                                                               {4{bodyTn[(4*j  )+1]}},
                                                                                               {4{bodyTn[(4*j  )+0]}}};
            zeroWriteEn[3][`TE/4*i+j] = {{8{bodyTm[`TE/2+(`TE/4*`COMPRATIO)*2*cnt+2*i+1]}},
                                         {8{bodyTm[`TE/2+(`TE/4*`COMPRATIO)*2*cnt+2*i  ]}}} & {{4{bodyTn[(4*j+2)+1]}}, 
                                                                                               {4{bodyTn[(4*j+2)+0]}},
                                                                                               {4{bodyTn[(4*j+2)+1]}},
                                                                                               {4{bodyTn[(4*j+2)+0]}}};
          end
        end      
      end
    endcase
  end

  // uopRdy
  always_comb begin
    vmelsuVld     = 'b0;
    resVme2rvvVld = 'b0;
    uopRdy        = 'b0;
    vmelsuresRdy  = 'b0;

    case(1'b1)
      isVme2Lsu: begin
        vmelsuVld = 1'b1;
        uopRdy[0] = 1'b1;
      end
      isLsu2Vme: begin
        uopRdy[0]     = 1'b1;
        vmelsuresRdy  = 1'b1;
      end
      isMv2Rvv: begin
        resVme2rvvVld = 1'b1;
        uopRdy[0]     = resVme2rvvRdy; 
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


  // MT accessing
`ifdef TB_SUPPORT
  // uop tracking
  logic [`NUM_BLK-1:0][`PC_WIDTH-1:0] readMtPc;
  logic [`NUM_BLK-1:0][`PC_WIDTH-1:0] writeMtPc;
`endif

  always_comb begin
    case(1'b1)
      isMv2Rvv,
      isVme2Lsu: begin
      `ifdef TB_SUPPORT
        readMtPc[0] = uop[0].uop_pc;
        readMtPc[1] = uop[0].uop_pc;
        readMtPc[2] = uop[0].uop_pc;
        readMtPc[3] = uop[0].uop_pc;
        writeMtPc   = 'b0;
      `endif
        readMtIdx   = mvlsuReadMtIdx;
        readSubIdx  = mvlsuReadSubIdx;
        writeEn     = 'b0;  
        writeMtIdx  = 'b0; 
        writeSubIdx = 'b0;
        writeData   = 'b0;
      end
      isMv2Vme,
      isLsu2Vme: begin
      `ifdef TB_SUPPORT
        readMtPc     = 'b0;
        writeMtPc[0] = uop[0].uop_pc;
        writeMtPc[1] = uop[0].uop_pc;
        writeMtPc[2] = uop[0].uop_pc;
        writeMtPc[3] = uop[0].uop_pc;
      `endif
        readMtIdx   = 'b0;
        readSubIdx  = 'b0;
        writeEn     = mvlsuWriteEn;  
        writeMtIdx  = mvlsuWriteMtIdx;
        writeSubIdx = mvlsuWriteSubIdx;
        writeData   = mvlsuWriteData;
      end
      isZero: begin  
      `ifdef TB_SUPPORT
        readMtPc     = 'b0;
        writeMtPc[0] = uop[0].uop_pc;
        writeMtPc[1] = uop[0].uop_pc;
        writeMtPc[2] = uop[0].uop_pc;
        writeMtPc[3] = uop[0].uop_pc;
      `endif
        readMtIdx   = 'b0;
        readSubIdx  = 'b0;
        writeEn     = zeroWriteEn;  
        writeMtIdx  = zeroWriteMtIdx;
        writeSubIdx = zeroWriteSubIdx;
        writeData   = 'b0;
      end
      default: begin
      `ifdef TB_SUPPORT
        readMtPc    = peReadPc;
        writeMtPc   = peWritePc;
      `endif
        readMtIdx   = peReadMtIdx;
        readSubIdx  = peReadSubIdx;
        writeEn     = peWriteEn;  
        writeMtIdx  = peWriteMtIdx;
        writeSubIdx = peWriteSubIdx;
        writeData   = peWriteData;
      end
    endcase
  end

  // retire cmd information 
  assign rtCmdVld       = isPe[0] ? &(peCmdVld&peCmdRdy) : !isMv2Rvv & uopVld[0] & uopRdy[0] & uop[0].last_uop_valid;
`ifdef TB_SUPPORT
  assign rtCmd.inst_pc  = uop[0].uop_pc;
`endif
  assign rtCmd.rob_tag  = uop[0].rob_tag;
  assign rtCmd.isStore  = isVme2Lsu;
  assign rtCmd.isLoad   = isLsu2Vme;
  assign rtCmd.isMv2Vme = isMv2Vme;
  assign rtCmd.isZero   = isZero;
  assign rtCmd.isPe     = isPe[0];
`ifdef RVVI_ON
  assign rtCmd.tssIndex = index;
  assign rtCmd.tssPattern = pattern;
  assign rtCmd.mt_index = (isMv2Vme || isLsu2Vme) ? tile : uop[0].dst_index[4:1];
  assign rtCmd.eew_mt   = uop[0].eew_mt;
  assign miscRtMtIdx    = (isMv2Vme || isLsu2Vme) ? tile : uop[0].dst_index[4:1];
`endif

  // Every rtCmd push must be matched by exactly one push into each of zvt's
  // four mtInfoRs FIFOs or vmeRt wedges. PE ops push those via peRtVld from
  // the array; every other op (lsu, moves, zero) pushes all four together
  // through miscRtVld, on the same cycle its rtCmd entry is pushed.
  always_comb begin
    case(1'b1) 
      isVme2Lsu,
      isLsu2Vme,
      isMv2Vme: miscRtVld = uopVld[0]&uopRdy[0]&uop[0].last_uop_valid;
      isZero:   miscRtVld = uopVld[0]&uopRdy[0]&cntCr;
      // isMv2Rvv: miscRtVld = 'b0;
      default:  miscRtVld = 'b0;
    endcase
  end

endmodule

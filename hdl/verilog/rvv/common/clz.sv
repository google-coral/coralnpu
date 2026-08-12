module clz(
  src,
  mode,
  cnt
);
  parameter   WIDTH     = 2;
  localparam  CNT_WIDTH = $clog2(WIDTH)+1;

//
// interface signals
//
  input   logic [WIDTH-1:0]     src;
  input   logic                 mode; // 0: count leading zero; 1: count tailing zero.
  output  logic [CNT_WIDTH-1:0] cnt;

//
// internal signals
//
  logic [WIDTH-1:0] source;

//
// code start
//
  always_comb begin
    if(mode==1) 
      for(int i=0;i<WIDTH;i++) source[i] = src[WIDTH-1-i];
    else 
      source = src;
  end

  generate
    if(WIDTH==32) 
      assign cnt = f_clzb32(source);
    else if(WIDTH==16) 
      assign cnt = f_clzb16(source);
    else if(WIDTH==8) 
      assign cnt = f_clzb8(source);
    else if(WIDTH==4) 
      assign cnt = f_clzb4(source);
    else if(WIDTH==2) 
      assign cnt = f_clzb2(source);
    else 
      $error("clz module does not this WIDTH=%d.\n", WIDTH);
  endgenerate
  
//
// function unit
//
  // count leading zero bits
  function [1:0] f_clzb2
  (   
    input logic [1:0] src
  );
    
    if (src[1])
      f_clzb2 = 2'b00;
    else if (src[0])
      f_clzb2 = 2'b01;
    else
      f_clzb2 = 2'b10;
  endfunction

  function [2:0] f_clzb4
  (
    input logic [3:0] src
  );

    logic [1:0] hi;
    logic [1:0] lo;

    hi = f_clzb2(src[3:2]);
    lo = f_clzb2(src[1:0]);
    if ((hi[1]==1'b1)&(lo[1]==1'b1))
      f_clzb4 = 3'b100;
    else if (hi[1]==1'b0)
      f_clzb4 = {1'b0,hi};
    else
      f_clzb4 = {2'b01,lo[0]};
  endfunction

  function [3:0] f_clzb8
  (
    input logic [7:0] src
  );

    logic [2:0] hi;
    logic [2:0] lo;

    hi = f_clzb4(src[7:4]);
    lo = f_clzb4(src[3:0]);
    if ((hi[2]==1'b1)&(lo[2]==1'b1))
      f_clzb8 = 4'b1000;
    else if (hi[2]==1'b0)
      f_clzb8 = {1'b0,hi};
    else
      f_clzb8 = {2'b01,lo[1:0]};
  endfunction

  function [4:0] f_clzb16
  (
    input logic [15:0] src
  );

    logic [3:0] hi;
    logic [3:0] lo;

    hi = f_clzb8(src[15:8]);
    lo = f_clzb8(src[7:0]);
    if ((hi[3]==1'b1)&(lo[3]==1'b1))
      f_clzb16 = 5'b1_0000;
    else if (hi[3]==1'b0)
      f_clzb16 = {1'b0,hi};
    else
      f_clzb16 = {2'b01,lo[2:0]};
  endfunction

  function [5:0] f_clzb32  
  (
    input logic [31:0] src
  );
    
    logic [4:0] hi;
    logic [4:0] lo;

    hi = f_clzb16(src[31:16]);
    lo = f_clzb16(src[15:0]);
    if ((hi[4]==1'b1)&(lo[4]==1'b1))
      f_clzb32 = 6'b10_0000;
    else if (hi[4]==1'b0)
      f_clzb32 = {1'b0,hi};
    else
      f_clzb32 = {2'b01,lo[3:0]};
  endfunction

endmodule

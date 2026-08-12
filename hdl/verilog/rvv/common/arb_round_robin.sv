module arb_round_robin (
  grant,
  grantData,
  req,
  reqData,
  clk,
  rst_n
);
  parameter REQ_NUM = 2;
  parameter type T  = logic;

  input   logic               clk;
  input   logic               rst_n;
  input   logic [REQ_NUM-1:0] req;
  input   T     [REQ_NUM-1:0] reqData;
  output  logic [REQ_NUM-1:0] grant;
  output  T                   grantData;

// ---internal signal definition--------------------------------------
  logic [REQ_NUM-1:0]   prio;
  logic [REQ_NUM-1:0]   prio_new;
  logic                 prio_en;
  logic [2*REQ_NUM-1:0] grant_tmp;
  
  assign grant_tmp  = {req,req} & ~({req,req} - (2*REQ_NUM)'(prio));
  assign grant      = grant_tmp[2*REQ_NUM-1:REQ_NUM] | grant_tmp[REQ_NUM-1:0];
  
  always_comb begin
    grantData = 'b0;

    for(int i=0; i<REQ_NUM; i++)
      if(grant[i]) grantData = reqData[i];
  end

  assign prio_en    = |req;
  assign prio_new   = {grant[REQ_NUM-2:0],grant[REQ_NUM-1]};

  edff #(
    .T      (logic [REQ_NUM-1:0]),
    .INIT   ((REQ_NUM)'('b1))
  ) priority_reg (
    .q      (prio), 
    .e      (prio_en), 
    .d      (prio_new), 
    .clk    (clk), 
    .rst_n  (rst_n)
  );

endmodule

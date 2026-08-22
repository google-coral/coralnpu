// edff - posedge ff, async rst_n, sync enable.

module edff (q, e, d, clk, rst_n
);
  parameter type T = logic;
  parameter T INIT  = T'(0);

  output T        q;

  input  logic    e;
  input  T        d;
  input  logic    clk;
  input  logic    rst_n;

  always @(posedge clk or negedge rst_n)
    if (!rst_n)   q <= INIT;
    else if (e)   q <= d;

endmodule

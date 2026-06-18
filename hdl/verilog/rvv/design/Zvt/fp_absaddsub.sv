module fp_absaddsub#(
  parameter int unsigned IN_WIDTH = 24,
  parameter logic PARALLEL_ADDSUB = 1'b1  // 1'b1: use dedicate b-a logic, 1'b0: output -(a-b) if a-b is negative
) (
  input  logic [IN_WIDTH-1:0] a,
  input  logic [IN_WIDTH-1:0] b,
  input  logic do_subtract,
  output logic [IN_WIDTH  :0] sum,
  output logic sum_negative
);

  // -b == ~b+1
  wire [IN_WIDTH-1:0] b_s = do_subtract ? ~b : b;
  wire carry_in = do_subtract;

  wire [IN_WIDTH:0] raw_sum = {1'b0, a}+b_s+carry_in;
  
  assign sum_negative = do_subtract && raw_sum[IN_WIDTH];

  generate if (PARALLEL_ADDSUB) begin
    assign sum = sum_negative ? ({1'b0, (b-a)}) : raw_sum;
  end else begin
    assign sum = sum_negative ? -raw_sum : raw_sum;
  end endgenerate

endmodule

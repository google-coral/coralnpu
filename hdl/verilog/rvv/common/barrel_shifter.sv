module barrel_shifter 
(
  din,            
  shift_amount,
  shift_mode,     
  dout            
);
  parameter   DATA_WIDTH    = 32;  
  localparam  SHIFT_WIDTH   = $clog2(DATA_WIDTH);
  localparam  SHIFT_SLL     = 2'b00;
  localparam  SHIFT_SRL     = 2'b01;
  localparam  SHIFT_SRA     = 2'b10;
//
// interface signals
//
  input  logic [DATA_WIDTH-1:0]   din;            
  input  logic [SHIFT_WIDTH-1:0]  shift_amount;
  input  logic [1:0]              shift_mode;
  output logic [DATA_WIDTH-1:0]   dout;     
  
//
// internal signals
//
  logic  [SHIFT_WIDTH:0][DATA_WIDTH-1:0] stage;
  
  assign stage[0] = din;
  assign dout     = stage[SHIFT_WIDTH];
  
  generate
    for(genvar j=0;j< SHIFT_WIDTH;j++) begin : gen_shift_stages
      localparam SHIFT_AMOUNT = 1<<j;

      always_comb begin
        if(shift_amount[j]) begin
          case(shift_mode)
            SHIFT_SLL: stage[j+1] = {stage[j][DATA_WIDTH-1-SHIFT_AMOUNT:0], {SHIFT_AMOUNT{1'b0}}};
            SHIFT_SRL: stage[j+1] = {{SHIFT_AMOUNT{1'b0}}, stage[j][DATA_WIDTH-1:SHIFT_AMOUNT]};
            SHIFT_SRA: stage[j+1] = {{SHIFT_AMOUNT{stage[j][DATA_WIDTH-1]}}, stage[j][DATA_WIDTH-1:SHIFT_AMOUNT]};
            default  : stage[j+1] = stage[j];
          endcase         
        end
        else begin
          stage[j+1] = stage[j];
        end
      end
    end
  endgenerate
  
endmodule

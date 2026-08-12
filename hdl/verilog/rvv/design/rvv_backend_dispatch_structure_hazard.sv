// description:
// 1. rvv_backend_dispatch_structure_hazard sub-module is used to check structure hazard
//    for uop(s)
//

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif

module rvv_backend_dispatch_structure_hazard
(
    rd_index,
    arch_hazard,
    strct_uop
);

//---port definition--------------------------------------------------
    output logic [`NUM_DP_VRF-1:0][`REGIDX_WIDTH-1:0] rd_index;
    output ARCH_HAZARD_t                              arch_hazard;
    input  STRCT_UOP_t [`NUM_DP_UOP-1:0]              strct_uop;
//---internal signal definition---------------------------------------
//---code start-------------------------------------------------------
//determine rd_index for VRF read ports

    generate
`ifdef DISPATCH3
      // 6 read ports of VRF
      // rd0 : uop0.vs1 or uop2 
      // rd1 : uop0.vs2 or uop2
      // rd2 : uop0.vs3 or uop2
      // rd3 : uop1.vs1 or uop2
      // rd4 : uop1.vs2 or uop2
      // rd5 : uop1.vs3 or uop2
      // check structure hazard for uop2
      always_comb begin
        rd_index[0] = strct_uop[0].vs1_index;
        rd_index[1] = strct_uop[0].vs2_index;
        rd_index[2] = strct_uop[0].vd_index;
        rd_index[3] = strct_uop[1].vs1_index;
        rd_index[4] = strct_uop[1].vs2_index;
        rd_index[5] = strct_uop[1].vd_index;
        
        arch_hazard.vr_limit = 1'b1;

        case(strct_uop[2].uop_class)
          XXX: begin
            arch_hazard.vr_limit = 'b0;
          end

          XXV,
          XVX,
          VXX: begin
            case(strct_uop[0].uop_class)
              XXV,
              XVV: begin
                case(1'b1)
                  strct_uop[2].vs3_valid: rd_index[2] = strct_uop[2].vd_index;
                  strct_uop[2].vs2_valid: rd_index[2] = strct_uop[2].vs2_index;
                  default:                rd_index[2] = strct_uop[2].vs1_index;
                endcase
                arch_hazard.vr_limit = 'b0;
              end

              XXX,
              XVX,
              VXX,
              VVX: begin
                case(1'b1)
                  strct_uop[2].vs3_valid: rd_index[0] = strct_uop[2].vd_index;
                  strct_uop[2].vs2_valid: rd_index[0] = strct_uop[2].vs2_index;
                  default:                rd_index[0] = strct_uop[2].vs1_index;
                endcase
                arch_hazard.vr_limit = 'b0;
              end

              VVV: begin 
                case(strct_uop[1].uop_class)
                  XXV,
                  XVV: begin
                    case(1'b1)
                      strct_uop[2].vs3_valid: rd_index[5] = strct_uop[2].vd_index;
                      strct_uop[2].vs2_valid: rd_index[5] = strct_uop[2].vs2_index;
                      default:                rd_index[5] = strct_uop[2].vs1_index;
                    endcase
                    arch_hazard.vr_limit = 'b0;
                  end

                  XXX,
                  XVX,
                  VXX,
                  VVX: begin
                    case(1'b1)
                      strct_uop[2].vs3_valid: rd_index[3] = strct_uop[2].vd_index;
                      strct_uop[2].vs2_valid: rd_index[3] = strct_uop[2].vs2_index;
                      default:                rd_index[3] = strct_uop[2].vs1_index;
                    endcase
                    arch_hazard.vr_limit = 'b0;
                  end

                  //VVV: arch_hazard.vr_limit = 'b1;
                endcase
              end
            endcase
          end
          
          XVV,
          VVX: begin
            case(strct_uop[0].uop_class)
              XXX,
              VXX: begin
                rd_index[0] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                       strct_uop[2].vd_index ;
                rd_index[1] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              XXV: begin
                rd_index[2] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                       strct_uop[2].vd_index ;
                rd_index[1] = strct_uop[2].vs2_index ;
                arch_hazard.vr_limit = 'b0;
              end

              XVX: begin
                rd_index[0] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                       strct_uop[2].vd_index ;
                rd_index[2] = strct_uop[2].vs2_index ;
                arch_hazard.vr_limit = 'b0;
              end

              XVV,
              VVX: begin
                case(strct_uop[1].uop_class)
                  XXX,
                  VXX: begin
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index ;
                    rd_index[4] = strct_uop[2].vs2_index ;
                    arch_hazard.vr_limit = 'b0;
                  end

                  XXV: begin
                    rd_index[5] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index ;
                    rd_index[4] = strct_uop[2].vs2_index ;
                    arch_hazard.vr_limit = 'b0;
                  end

                  XVX: begin
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index ;
                    rd_index[5] = strct_uop[2].vs2_index ;
                    arch_hazard.vr_limit = 'b0;
                  end   

                  VVX: begin
                    if (strct_uop[0].vs1_valid=='b0) 
                      rd_index[0] = strct_uop[2].vs2_index;
                    else 
                      rd_index[2] = strct_uop[2].vs2_index;
                    
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    arch_hazard.vr_limit = 'b0;
                  end

                  XVV: begin
                    if (strct_uop[0].vs1_valid=='b0) 
                      rd_index[0] = strct_uop[2].vs2_index;
                    else 
                      rd_index[2] = strct_uop[2].vs2_index;

                    rd_index[5] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    arch_hazard.vr_limit = 'b0;
                  end
                endcase
              end

              VVV: begin 
                case(strct_uop[1].uop_class)
                  XXX,
                  VXX: begin
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    rd_index[4] = strct_uop[2].vs2_index ; 
                    arch_hazard.vr_limit = 'b0;
                  end

                  XVX: begin
                    rd_index[3] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    rd_index[5] = strct_uop[2].vs2_index ; 
                    arch_hazard.vr_limit = 'b0;
                  end

                  XXV: begin
                    rd_index[4] = strct_uop[2].vs1_valid ? strct_uop[2].vs1_index : 
                                                           strct_uop[2].vd_index;
                    rd_index[5] = strct_uop[2].vs2_index ; 
                    arch_hazard.vr_limit = 'b0;
                  end

                  VVV: begin
                    arch_hazard.vr_limit = 'b1;
                  end
                endcase
              end
            endcase
          end

          VVV: begin
            case({strct_uop[0].uop_class,strct_uop[1].uop_class})
              {XXX,XXX},
              {XXX,XXV},
              {XXX,XVX},
              {XXX,VXX},
              {XXX,XVV},
              {XXX,VVX},
              {XXX,VVV}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[2] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XXV,XXX},
              {XVX,XXX},
              {VXX,XXX},
              {XVV,XXX},
              {VVX,XXX},
              {VVV,XXX}: begin
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XXV,VXX},
              {XXV,VVX}: begin
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[3] = strct_uop[2].vs1_index;
                arch_hazard.vr_limit = 'b0;
              end
              
              {XXV,XXV},
              {XXV,XVX},
              {XXV,XVV}: begin
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[5] = strct_uop[2].vs1_index;
                arch_hazard.vr_limit = 'b0;
              end
              
              {XVX,VXX},
              {XVX,VVX}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[3] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XVX,XXV},
              {XVX,XVX},
              {XVX,XVV}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[5] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VXX,VXX},
              {VXX,VVX}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[3] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VXX,XXV},
              {VXX,XVX},
              {VXX,XVV}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[1] = strct_uop[2].vs2_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XVV,VXX}: begin
                rd_index[2] = strct_uop[2].vd_index;
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XVV,XVX}: begin
                rd_index[2] = strct_uop[2].vs2_index;
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {XVV,XXV}: begin
                rd_index[2] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VVX,VXX}: begin
                rd_index[0] = strct_uop[2].vd_index;
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VVX,XVX}: begin
                rd_index[0] = strct_uop[2].vs2_index;
                rd_index[3] = strct_uop[2].vs1_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              {VVX,XXV}: begin
                rd_index[0] = strct_uop[2].vs1_index;
                rd_index[4] = strct_uop[2].vs2_index;
                rd_index[5] = strct_uop[2].vd_index;
                arch_hazard.vr_limit = 'b0;
              end

              default: begin
                arch_hazard.vr_limit = 'b1;
              end
            endcase
          end
        endcase
      end

`else // DISPATCH2
      // 4 read ports of VRF
      // rd0: uop0.vs2 or uop0.vs1 or uop0.vd
      // rd1: uop0.vs1 or uop1.vd
      // rd2: uop1.vs2 or uop1.vs1 or uop1.vd
      // rd3: uop1.vs1 or uop0.vd
      always_comb begin
        // read port[0] of VRF
        case(strct_uop[0].uop_class)
          VVV,
          XVV,                      
          VVX,
          XVX: begin
            rd_index[0] = strct_uop[0].vs2_index;
          end
          VXX: begin
            rd_index[0] = strct_uop[0].vd_index;
          end
          XXV: begin
            rd_index[0] = strct_uop[0].vs1_index;
          end
          default: begin
            rd_index[0] = 'x;
          end
        endcase
        // rd[1]
        case(strct_uop[0].uop_class)
          VVV,
          XVV:begin                       
            rd_index[1] = strct_uop[0].vs1_index;
          end
          VVX: begin
            rd_index[1] = strct_uop[0].vd_index;
          end
          VXX,
          XVX,
          XXV,
          XXX: begin
            rd_index[1] = strct_uop[1].uop_class==VVV ? strct_uop[1].vd_index : 'x;
          end
          default: begin
            rd_index[1] = strct_uop[1].uop_class==VVV ? strct_uop[1].vd_index : 'x;
          end
        endcase
        // rd[2]
        case(strct_uop[1].uop_class)
          VVV,
          XVV,                      
          VVX,
          XVX: begin
            rd_index[2] = strct_uop[1].vs2_index;
          end
          VXX: begin
            rd_index[2] = strct_uop[1].vd_index;
          end
          XXV: begin
            rd_index[2] = strct_uop[1].vs1_index;
          end
          default: begin
            rd_index[2] = 'x;
          end
        endcase
        // rd[3]
        case(strct_uop[1].uop_class)
          VVV,
          XVV:begin                       
            rd_index[3] = strct_uop[0].uop_class==VVV ? strct_uop[0].vd_index : strct_uop[1].vs1_index;
          end
          VVX: begin
            rd_index[3] = strct_uop[0].uop_class==VVV ? strct_uop[0].vd_index : strct_uop[1].vd_index;
          end
          VXX,
          XVX,
          XXV,
          XXX: begin
            rd_index[3] = strct_uop[0].uop_class==VVV ? strct_uop[0].vd_index : 'x;
          end
          default: begin
            rd_index[3] = strct_uop[0].uop_class==VVV ? strct_uop[0].vd_index : 'x;
          end
        endcase
      end

      //check structure hazard
      always_comb begin
        case({strct_uop[0].uop_class, strct_uop[1].uop_class})
          {VVV, VVV},
          {VVV, XVV},
          {VVV, VVX},
          {XVV, VVV},
          {VVX, VVV}: arch_hazard.vr_limit = 1'b1;
          default:    arch_hazard.vr_limit = 1'b0;
        endcase
      end

`endif
    endgenerate

endmodule

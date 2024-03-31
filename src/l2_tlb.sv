module l2_tlb import ariane_pkg::*;
#(
      parameter int unsigned SETS   = 128,
      parameter int unsigned WAYS   = 1,
      parameter int unsigned POW    = 7,
      parameter int unsigned ASID_WIDTH  = 1
  )(
    input  logic                    clk_i,    // Clock
    input  logic                    rst_ni,   // Asynchronous reset active low
    input  logic                    flush_i,  // Flush signal
    //From MMU
    input  logic                    dtlb_lu_access_i,
    input  logic                    itlb_lu_access_i,
    input  logic [riscv::VLEN-1:0]  dtlb_vaddr_i,
    input  logic [riscv::VLEN-1:0]  itlb_vaddr_i,
    input  logic [ASID_WIDTH-1:0]   asid_to_be_flushed_i,
    input  logic [riscv::VLEN-1:0]  vaddr_to_be_flushed_i,
    // input  logic        [ ASID_WIDTH-1:0] lu_asid_i,


    //Update L2 TLB from PTW
    input  tlb_update_t             itlb_update_in,
    input  tlb_update_t             dtlb_update_in,

    //Signals from L1 TLB
    input  logic                     l1_dtlb_hit,
    input  logic                     l1_itlb_hit,

    // Update L1 Tlb
    output  tlb_update_t             l1_tlb_update_o,

    //Signals to PTW
    output  logic                    l2_tlb_hit_o,

    //Signals
    input  logic                    enable_translation_i,  // CSRs indicate to enable SV39
    input  logic                    en_ld_st_translation_i // enable virtual memory translation for load/stores
);

    // tlb_update_t [SETS-1:0][WAYS-1:0] SRAM_q = '{default: 0};

    struct packed {
      logic [ASID_WIDTH-1:0] asid;
      logic [26:0]           vpn;
      logic                  is_2M;
      logic                  is_1G;
      logic                  valid;
    } [SETS-1:0][WAYS-1:0] SRAM_q, SRAM_n;

    riscv::pte_t [SETS-1:0][WAYS-1:0] content_q, content_n;

    logic [26:0] vpn = '{default: 0};
    logic [POW-1:0] index;
    logic [POW-1:0] flush_index;
    
    logic asid_to_be_flushed_is0;  // indicates that the ASID provided by SFENCE.VMA (rs2)is 0, active high
    logic vaddr_to_be_flushed_is0;  // indicates that the VADDR provided by SFENCE.VMA (rs1)is 0, active high
    logic vaddr_vpn_match_l2;
    
    reg [9:0] lfsr_reg;

    logic sent, updated;
    int  i, k, j;
    int fd;

    always_comb begin : values_l2_tlb
        if (~l1_itlb_hit && itlb_lu_access_i && ~dtlb_lu_access_i && enable_translation_i && ~dtlb_update_in.valid && ~itlb_update_in.valid) begin
            sent = 0;
            updated = 0;
            index = itlb_vaddr_i[POW-1+12:12];
            vpn = itlb_vaddr_i[30+riscv::VPN2:12];
        end
        else if (~l1_dtlb_hit && en_ld_st_translation_i && dtlb_lu_access_i && ~dtlb_update_in.valid && ~itlb_update_in.valid) begin
            sent = 0;
            updated = 0;
            index = dtlb_vaddr_i[POW-1+12:12];
            vpn = dtlb_vaddr_i[30+riscv::VPN2:12];
        end
    end

    always_comb begin : translation_l2_tlb
        // default assignment
        l2_tlb_hit_o            = 1'b0;
        l1_tlb_update_o.valid   = 1'b0;
        l1_tlb_update_o.is_1G   = 1'b0;
        l1_tlb_update_o.is_2M   = 1'b0;
        l1_tlb_update_o.content = '{default: 0};

        for (i = 0; i<WAYS; i++) begin
            //-------------
            // Translation
            //-------------
            if(vpn == SRAM_q[index][i].vpn &&  SRAM_q[index][i].valid && dtlb_update_in.valid==0 && itlb_update_in.valid==0 && sent == 0 && updated == 0)begin
                l2_tlb_hit_o                           = 1'b1;
                l1_tlb_update_o.vpn                    = SRAM_q[index][i].vpn;
                l1_tlb_update_o.asid                   = SRAM_q[index][i].asid;
                l1_tlb_update_o.is_1G                  = SRAM_q[index][i].is_1G;
                l1_tlb_update_o.is_2M                  = SRAM_q[index][i].is_2M;
                l1_tlb_update_o.content                = content_q[index][i];
                l1_tlb_update_o.valid                  = 1'b1;
                sent                                   = 1;
                $fdisplay(fd, "%t L2 TLB hit -- index: %h way: %d -- tag: %h", $time, index, i, SRAM_q[index][i].vpn);
                break;
            end
        end
    end

    assign asid_to_be_flushed_is0 =  ~(|asid_to_be_flushed_i);
    assign vaddr_to_be_flushed_is0 = ~(|vaddr_to_be_flushed_i);


    always_comb begin : update_l2_tlb
        flush_index = vaddr_to_be_flushed_i[POW-1+12:12];
        SRAM_n    = SRAM_q;
        content_n = content_q;
        for (i = 0; i<WAYS; i++) begin
            vaddr_vpn_match_l2 = (vaddr_to_be_flushed_i[30+riscv::VPN2:12] == SRAM_q[flush_index][i].vpn[18+riscv::VPN2:0]);
            if (flush_i) begin
                if (asid_to_be_flushed_is0 && vaddr_to_be_flushed_is0) begin
                    $fdisplay(fd, "%t 1 index: %h", $time, flush_index);
                    for (j = 0; j<SETS; j++) begin
                        SRAM_n[j][i].valid = 1'b0;
                    end
                end else if(vaddr_vpn_match_l2) begin
                    $fdisplay(fd, "%t 2 index: %h i: %d", $time, flush_index, i);
                    SRAM_n[flush_index][i].valid = 1'b0;
                end

            end else begin
                // ------------------
                // Update itlb from PTW
                // ------------------
                if(itlb_update_in.vpn == SRAM_n[index][i].vpn && itlb_update_in.valid &&  SRAM_n[index][i].valid == 1'b1)
                    break;
                else if (itlb_update_in.valid && (SRAM_n[index][i].valid==0 || i==WAYS-1)) begin
                    if (SRAM_n[index][i].valid==0 || WAYS == 1) begin
                        k = i;
                    end else if (SRAM_n[index][i].valid!=0 && i==WAYS-1) begin
                        k = lfsr_reg % (WAYS);
                        $fdisplay(fd, "%t random: %d lfsr_reg: %d", $time, k, lfsr_reg);
                    end
                    SRAM_n[index][k] = '{
                        asid       : itlb_update_in.asid,
                        vpn        : itlb_update_in.vpn,
                        is_1G      : itlb_update_in.is_1G,
                        is_2M      : itlb_update_in.is_2M,
                        valid      : 1'b1
                    };
                    content_n[index][k] = itlb_update_in.content;
                    updated           = 1;
                    $fdisplay(fd, "%t L2: Update itlb array: %h cont: %d index: %d i: %d", $time, itlb_update_in.vpn[18+riscv::VPN2:0], content_n[index][k], index, k);
                    break;
                end

                // ------------------
                // Update dtlb from PTW
                // ------------------
                if(dtlb_update_in.vpn == SRAM_n[index][i].vpn && dtlb_update_in.valid &&  SRAM_n[index][i].valid == 1'b1)
                    break;
                else if (dtlb_update_in.valid && (SRAM_n[index][i].valid==0 || i==WAYS-1)) begin
                    if (SRAM_n[index][i].valid==0 || WAYS == 1) begin
                        k = i;
                    end else if (SRAM_n[index][i].valid!=0 && i==WAYS-1) begin
                        k = lfsr_reg % (WAYS);
                        $fdisplay(fd, "%t random: %d lfsr_reg: %d", $time, k, lfsr_reg);
                    end
                    SRAM_n[index][k] = '{
                        asid       : dtlb_update_in.asid,
                        vpn        : dtlb_update_in.vpn,
                        is_1G      : dtlb_update_in.is_1G,
                        is_2M      : dtlb_update_in.is_2M,
                        valid      : 1'b1
                    };
                    content_n[index][k] = dtlb_update_in.content;
                    updated           = 1;
                    $fdisplay(fd, "%t L2: Update dtlb array: %h cont: %d index: %d i: %d", $time, dtlb_update_in.vpn[18+riscv::VPN2:0], content_n[index][k], index, k);
                    break;
                end
            end
        end
    end

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(~rst_ni) begin
            SRAM_q      <= '{default: 0};
            content_q   <= '{default: 0};
            lfsr_reg    <= 10'b1111111111;
        end else begin
            SRAM_q      <= SRAM_n;
            content_q   <= content_n;
            lfsr_reg    <= {lfsr_reg[8:0], lfsr_reg[9] ^ lfsr_reg[5]};
        end
    end

    initial begin
        fd = $fopen("l2_tlb.txt", "w");
    end
endmodule
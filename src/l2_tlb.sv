module l2_tlb
  import ariane_pkg::*;
#(
    parameter int L2_TLB_DEPTH = 128,
    parameter int L2_TLB_WAYS = 4,
    parameter int unsigned ASID_WIDTH  = 1
) (
    input logic clk_i,   // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i,

    input logic enable_translation_i,   // CSRs indicate to enable SV39
    input logic en_ld_st_translation_i, // enable virtual memory translation for load/stores

    input logic [ASID_WIDTH-1:0] asid_i,

    // from TLBs
    // did we miss?
    input logic                    itlb_access_i,
    input logic                    itlb_hit_i,
    input logic [riscv::VLEN-1:0] itlb_vaddr_i,

    input logic                    dtlb_access_i,
    input logic                    dtlb_hit_i,
    input logic [riscv::VLEN-1:0] dtlb_vaddr_i,

    // to TLBs, update logic
    output tlb_update_t itlb_update_o,
    output tlb_update_t dtlb_update_o,

    output logic                    l2_tlb_hit_o,

    // Update l2 TLB in case of miss
    input tlb_update_t l2_tlb_update_itlb_i,
    input tlb_update_t l2_tlb_update_dtlb_i
    //input tlb_update_t l2_tlb_update

);
  
  function logic [L2_TLB_WAYS-1:0] l2_tlb_way_bin2oh(input logic [$clog2(L2_TLB_WAYS)-1:0] in);
    logic [L2_TLB_WAYS-1:0] out;
    out     = '0;
    out[in] = 1'b1;
    return out;
  endfunction

  typedef struct packed {
    logic [15:0] asid;   //16 bits wide
    logic [8:0]  vpn2;   //9 bits wide
    logic [8:0]  vpn1;   //9 bits wide
    logic [8:0]  vpn0;   //9 bits wide
    logic        is_2M;
    logic        is_1G;
    logic        napot_bits;
  } l2_tag_t;

  tlb_update_t l2_tlb_update;
  l2_tag_t l2_tag_wr;
  l2_tag_t [L2_TLB_WAYS-1:0] l2_tag_rd;

  logic [L2_TLB_DEPTH-1:0][L2_TLB_WAYS-1:0] l2_tag_valid_q, l2_tag_valid_d;

  logic [         L2_TLB_WAYS-1:0] l2_tag_valid;

  logic [         L2_TLB_WAYS-1:0] tag_wr_en;
  logic [$clog2(L2_TLB_DEPTH)-1:0] tag_wr_addr;
  logic [     $bits(l2_tag_t)-1:0] tag_wr_data;

  logic [         L2_TLB_WAYS-1:0] tag_rd_en;
  logic [$clog2(L2_TLB_DEPTH)-1:0] tag_rd_addr;
  logic [     $bits(l2_tag_t)-1:0] tag_rd_data      [L2_TLB_WAYS-1:0];

  logic [         L2_TLB_WAYS-1:0] tag_req;
  logic [         L2_TLB_WAYS-1:0] tag_we;
  logic [$clog2(L2_TLB_DEPTH)-1:0] tag_addr;

  logic [         L2_TLB_WAYS-1:0] pte_wr_en;
  logic [$clog2(L2_TLB_DEPTH)-1:0] pte_wr_addr;
  logic [$bits(riscv::pte_t)-1:0] pte_wr_data;

  logic [         L2_TLB_WAYS-1:0] pte_rd_en;
  logic [$clog2(L2_TLB_DEPTH)-1:0] pte_rd_addr;
  logic [$bits(riscv::pte_t)-1:0] pte_rd_data      [L2_TLB_WAYS-1:0];

  logic [         L2_TLB_WAYS-1:0] pte_req;
  logic [         L2_TLB_WAYS-1:0] pte_we;
  logic [$clog2(L2_TLB_DEPTH)-1:0] pte_addr;

  logic [8:0] vpn0_d, vpn1_d, vpn2_d, vpn0_q, vpn1_q, vpn2_q;

  riscv::pte_t [L2_TLB_WAYS-1:0] pte;

  logic [riscv::VLEN-1-12:0] itlb_vpn_q;
  logic [riscv::VLEN-1-12:0] dtlb_vpn_q;

  logic [ASID_WIDTH-1:0] tlb_update_asid_q, tlb_update_asid_d;

  logic l2_tlb_hit_d;

  logic itlb_req_d, itlb_req_q;
  logic dtlb_req_d, dtlb_req_q;

  // replacement strategy
  logic [L2_TLB_WAYS-1:0] way_valid;
  logic update_lfsr;  // shift the LFSR
  logic [$clog2(L2_TLB_WAYS)-1:0] inv_way;  // first non-valid encountered
  logic [$clog2(L2_TLB_WAYS)-1:0] rnd_way;  // random index for replacement
  logic [$clog2(L2_TLB_WAYS)-1:0] repl_way;  // way to replace
  logic [L2_TLB_WAYS-1:0] repl_way_oh_d;  // way to replace (onehot)
  logic all_ways_valid;  // we need to switch repl strategy since all are valid

  assign l2_tlb_hit_o = l2_tlb_hit_d;

    //-------------
    // New Values
    //-------------

  always_comb begin : itlb_dtlb_miss
    vpn0_d              = vpn0_q;
    vpn1_d              = vpn1_q;
    vpn2_d              = vpn2_q;

    tag_rd_en           = '0;
    pte_rd_en           = '0;

    itlb_req_d          = 1'b0;
    dtlb_req_d          = 1'b0;

    tlb_update_asid_d   = tlb_update_asid_q;

    tag_rd_addr         = '0;
    pte_rd_addr         = '0;

    // if we got an ITLB miss
    if (enable_translation_i & itlb_access_i & ~itlb_hit_i & ~dtlb_access_i) begin
      tag_rd_en           = '1;
      tag_rd_addr         = itlb_vaddr_i[16+:$clog2(L2_TLB_DEPTH)];
      pte_rd_en           = '1;
      pte_rd_addr         = itlb_vaddr_i[16+:$clog2(L2_TLB_DEPTH)];

      vpn0_d              = itlb_vaddr_i[20:12];
      vpn1_d              = itlb_vaddr_i[29:21];
      vpn2_d              = itlb_vaddr_i[38:30];

      itlb_req_d          = 1'b1;

      tlb_update_asid_d   = asid_i;
      // we got an DTLB miss
    end else if (en_ld_st_translation_i & dtlb_access_i & ~dtlb_hit_i) begin
      tag_rd_en           = '1;
      tag_rd_addr         = dtlb_vaddr_i[16+:$clog2(L2_TLB_DEPTH)];
      pte_rd_en           = '1;
      pte_rd_addr         = dtlb_vaddr_i[16+:$clog2(L2_TLB_DEPTH)];

      vpn0_d              = dtlb_vaddr_i[20:12];
      vpn1_d              = dtlb_vaddr_i[29:21];
      vpn2_d              = dtlb_vaddr_i[38:30];

      dtlb_req_d          = 1'b1;

      tlb_update_asid_d   = asid_i;
    end
  end  //itlb_dtlb_miss
  
  
  //-------------
  // Translation
  //-------------
  always_comb begin : tag_comparison
    l2_tlb_hit_d = 1'b0;
    dtlb_update_o = '0;
    itlb_update_o = '0;
    //number of ways
    for (int unsigned i = 0; i < L2_TLB_WAYS; i++) begin
        if (l2_tag_valid[i]  && ((asid_i == l2_tag_rd[i].asid) || pte[i].g) && (l2_tag_rd[i].is_2M || vpn0_q == l2_tag_rd[i].vpn0 || (l2_tag_rd[i].napot_bits && vpn0_q[8:4] == l2_tag_rd[i].vpn0[8:4])) && vpn1_q == l2_tag_rd[i].vpn1 && vpn2_q == l2_tag_rd[i].vpn2) begin
            if (itlb_req_q) begin
                l2_tlb_hit_d = 1'b1;
                itlb_update_o.valid = 1'b1;
                itlb_update_o.vpn = itlb_vpn_q;
                itlb_update_o.is_1G = 1'b0;//l2_tag_rd[i].is_1G;
		            itlb_update_o.napot_bits = 1'b0;
                itlb_update_o.is_2M = l2_tag_rd[i].is_2M;
                itlb_update_o.asid = tlb_update_asid_q;
                itlb_update_o.content = pte[i];
            end else if (dtlb_req_q) begin
                l2_tlb_hit_d = 1'b1;
                dtlb_update_o.valid = 1'b1;
                dtlb_update_o.vpn = dtlb_vpn_q;
                dtlb_update_o.is_1G = 1'b0;//l2_tag_rd[i].is_1G;
		            dtlb_update_o.napot_bits = l2_tag_rd[i].napot_bits;
                dtlb_update_o.is_2M = l2_tag_rd[i].is_2M;
                dtlb_update_o.asid = tlb_update_asid_q;
                dtlb_update_o.content = pte[i];
            end
        end

    end
  end  //tag_comparison


// sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      itlb_vpn_q <= '0;
      dtlb_vpn_q <= '0;
      tlb_update_asid_q <= '0;
      l2_tag_valid_q <= '0;
      vpn0_q <= '0;
      vpn1_q <= '0;
      vpn2_q <= '0;
      itlb_req_q <= '0;
      dtlb_req_q <= '0;
      l2_tag_valid <= '0;
    end else begin
      itlb_vpn_q <= itlb_vaddr_i[38:12];
      dtlb_vpn_q <= dtlb_vaddr_i[38:12];
      tlb_update_asid_q <= tlb_update_asid_d;
      l2_tag_valid_q <= l2_tag_valid_d;
      vpn0_q <= vpn0_d;
      vpn1_q <= vpn1_d;
      vpn2_q <= vpn2_d;
      itlb_req_q <= itlb_req_d;
      dtlb_req_q <= dtlb_req_d;
      l2_tag_valid <= l2_tag_valid_q[tag_rd_addr];
    end
  end

  // ------------------
  // Update and Flush signals
  // ------------------
  assign l2_tlb_update = (l2_tlb_update_itlb_i.valid) ? l2_tlb_update_itlb_i : (l2_tlb_update_dtlb_i.valid) ? l2_tlb_update_dtlb_i : '0;
  
  always_comb begin : update_flush
    l2_tag_valid_d = l2_tag_valid_q;
    tag_wr_en = '0;
    pte_wr_en = '0;

    if (flush_i) begin
      l2_tag_valid_d = '0;
    end else if (l2_tlb_update.valid) begin
      for (int unsigned i = 0; i < L2_TLB_WAYS; i++) begin
        if (repl_way_oh_d[i]) begin
          l2_tag_valid_d[l2_tlb_update.vpn[4+:$clog2(L2_TLB_DEPTH)]][i] = 1'b1;
          tag_wr_en[i] = 1'b1;
          pte_wr_en[i] = 1'b1;
        end
      end
    end
  end  //update_flush

  // Update form ptw
  assign l2_tag_wr.asid = l2_tlb_update.asid;
  assign l2_tag_wr.vpn2 = l2_tlb_update.vpn[24:18];
  assign l2_tag_wr.vpn1 = l2_tlb_update.vpn[17:9];
  assign l2_tag_wr.vpn0 = l2_tlb_update.vpn[8:0];
  assign l2_tag_wr.is_1G = l2_tlb_update.is_1G;
  assign l2_tag_wr.is_2M = l2_tlb_update.is_2M;
  assign l2_tag_wr.napot_bits = l2_tlb_update.napot_bits;

  assign tag_wr_addr = l2_tlb_update.vpn[4+:$clog2(L2_TLB_DEPTH)];
  assign tag_wr_data = l2_tag_wr;

  assign pte_wr_addr = l2_tlb_update.vpn[4+:$clog2(L2_TLB_DEPTH)];
  assign pte_wr_data = l2_tlb_update.content;
  
  //replacement
  assign way_valid = l2_tag_valid_q[l2_tlb_update.vpn[4+:$clog2(L2_TLB_DEPTH)]];
  assign repl_way = (all_ways_valid) ? rnd_way : inv_way;
  assign update_lfsr = l2_tlb_update.valid & all_ways_valid;
  assign repl_way_oh_d = (l2_tlb_update.valid) ? l2_tlb_way_bin2oh(repl_way) : '0;
  //assign repl_way_oh_d = (l2_tlb_update.valid) ? l2_tlb_way_bin2oh(rnd_way) : '0;

  lzc #(
      .WIDTH(L2_TLB_WAYS)
  ) i_lzc (
      .in_i   (~way_valid),
      .cnt_o  (inv_way),
      .empty_o(all_ways_valid)
  );

  lfsr #(
      .LfsrWidth(8),
      .OutWidth ($clog2(L2_TLB_WAYS))
  ) i_lfsr (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .en_i  (update_lfsr),
      .out_o (rnd_way)
  );
    // ------------------
    // memory arrays and regs
    // ------------------
 
  assign tag_req  = tag_wr_en | tag_rd_en;
  assign tag_we   = tag_wr_en;
  assign tag_addr = tag_wr_en ? tag_wr_addr : tag_rd_addr;

  assign pte_req  = pte_wr_en | pte_rd_en;
  assign pte_we   = pte_wr_en;
  assign pte_addr = pte_wr_en ? pte_wr_addr : pte_rd_addr;

  for (genvar i = 0; i < L2_TLB_WAYS; i++) begin : gen_sram
    // Tag RAM
    sram #(
        .DATA_WIDTH($bits(l2_tag_t)),
        .NUM_WORDS (L2_TLB_DEPTH)
    ) tag_sram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (tag_req[i]),
        .we_i   (tag_we[i]),
        .addr_i (tag_addr),
        .wdata_i(tag_wr_data),
        .be_i   ('1),
        .rdata_o(tag_rd_data[i])
    );

    assign l2_tag_rd[i] = l2_tag_t'(tag_rd_data[i]);

    // PTE RAM
    sram #(
        .DATA_WIDTH($bits(riscv::pte_t)),
        .NUM_WORDS (L2_TLB_DEPTH)
    ) pte_sram (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (pte_req[i]),
        .we_i   (pte_we[i]),
        .addr_i (pte_addr),
        .wdata_i(pte_wr_data),
        .be_i   ('1),
        .rdata_o(pte_rd_data[i])
    );
    assign pte[i] = riscv::pte_t'(pte_rd_data[i]);
  end
endmodule

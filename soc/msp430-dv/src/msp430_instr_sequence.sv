/*
 * Copyright 2018 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//-----------------------------------------------------------------------------------------
// RISC-V instruction sequence
//
// This class is used to generate a single instruction sequence for a RISC-V assembly program.
// It's used by msp430_asm_program_gen to generate the main program and all sub-programs. The
// flow is explained below:
// For main program:
// - Generate instruction sequence body.
// - Post-process the load/store/branch instructions.
// - Insert the jump instructions to its sub-programs (done by msp430_asm_program_gen).
// For sub program:
// - Generate the stack push instructions which are executed when entering this program.
// - Generate instruction sequence body.
// - Generate the stack pop instructions which are executed before exiting this program.
// - Post-process the load/store/branch instructions.
// - Insert the jump instructions to its sub-programs (done by msp430_asm_program_gen).
// - Generate a return instruction at the end of the program.
//-----------------------------------------------------------------------------------------

class msp430_instr_sequence extends uvm_sequence;

  int unsigned             instr_cnt;            // Instruction count of this sequence
  msp430_push_stack_instr   instr_stack_enter;    // Stack push instructions for sub-programs
  msp430_pop_stack_instr    instr_stack_exit;     // Stack pop instructions for sub-programs
  msp430_rand_instr_stream  instr_stream;         // Main instruction streams
  bit                      is_main_program;      // Type of this sequence (main or sub program)
  bit                      is_debug_program;     // Indicates whether sequence is debug program
  string                   label_name;           // Label of the sequence (program name)
  msp430_instr_gen_config   cfg;                  // Configuration class handle
  string                   instr_string_list[$]; // Save the instruction list in string format
  int                      program_stack_len;    // Stack space allocated for this program
  msp430_instr_stream       directed_instr[];     // List of all directed instruction stream
  msp430_illegal_instr      illegal_instr;        // Illegal instruction generator
  int                      illegal_instr_pct;    // Percentage of illegal instruction
  int                      hint_instr_pct;       // Percentage of HINT instruction

  `uvm_object_utils(msp430_instr_sequence)

  function new (string name = "");
    super.new(name);
    if(!uvm_config_db#(msp430_instr_gen_config)::get(null, "*", "instr_cfg", cfg))
      `uvm_fatal(get_full_name(), "Cannot get instr_gen_cfg")
    instr_stream = msp430_rand_instr_stream::type_id::create("instr_stream");
    instr_stack_enter = msp430_push_stack_instr::type_id::create("instr_stack_enter");
    instr_stack_exit  = msp430_pop_stack_instr::type_id::create("instr_stack_exit");
    illegal_instr = msp430_illegal_instr::type_id::create("illegal_instr");
  endfunction

  // Main function to generate the instruction stream
  // The main random instruction stream is generated by instr_stream.gen_instr(), which generates
  // each instruction one by one with a separate randomization call. It's not done by a single
  // randomization call for the entire instruction stream because this solution won't scale if
  // we have hundreds of thousands of instructions to generate. The constraint solver slows down
  // considerably as the instruction stream becomes longer. The downside is we cannot specify
  // constraints between instructions. The way to solve it is to have a dedicated directed
  // instruction stream for such scenarios, like hazard sequence.
  virtual function void gen_instr(bit is_main_program, bit no_branch = 1'b0);
    this.is_main_program = is_main_program;
    instr_stream.cfg = cfg;
    instr_stream.initialize_instr_list(instr_cnt);
    `uvm_info(get_full_name(), $sformatf("Start generating %0d instruction",
                               instr_stream.instr_list.size()), UVM_LOW)
    // Do not generate load/store instruction here
    // The load/store instruction will be inserted as directed instruction stream
    instr_stream.gen_instr(.no_branch(no_branch), .no_load_store(1'b1),
                           .is_debug_program(is_debug_program));
    if(!is_main_program) begin
      gen_stack_enter_instr();
      gen_stack_exit_instr();
    end
    `uvm_info(get_full_name(), "Finishing instruction generation", UVM_LOW)
  endfunction

  // Generate the stack push operations for this program
  // It pushes the necessary context to the stack like RA, T0,loop registers etc. The stack
  // pointer(SP) is reduced by the amount the stack space allocated to this program.
  function void gen_stack_enter_instr();
    bit allow_branch = ((illegal_instr_pct > 0) || (hint_instr_pct > 0)) ? 1'b0 : 1'b1;
    allow_branch &= !cfg.no_branch_jump;
    `DV_CHECK_STD_RANDOMIZE_WITH_FATAL(program_stack_len,
      program_stack_len inside {[cfg.min_stack_len_per_program : cfg.max_stack_len_per_program]};
      // Keep stack len word aligned to avoid unaligned load/store
      program_stack_len % (XLEN/8) == 0;,
      "Cannot randomize program_stack_len")
    instr_stack_enter.cfg = cfg;
    instr_stack_enter.push_start_label = {label_name, "_stack_p"};
    instr_stack_enter.gen_push_stack_instr(program_stack_len, .allow_branch(allow_branch));
    instr_stream.instr_list = {instr_stack_enter.instr_list, instr_stream.instr_list};
  endfunction

  // Recover the saved GPR from the stack
  // Advance the stack pointer(SP) to release the allocated stack space.
  function void gen_stack_exit_instr();
    instr_stack_exit.cfg = cfg;
    instr_stack_exit.gen_pop_stack_instr(
                     program_stack_len, instr_stack_enter.saved_regs);
    instr_stream.instr_list = {instr_stream.instr_list, instr_stack_exit.instr_list};
  endfunction

  //----------------------------------------------------------------------------------------------
  // Instruction post-process
  //
  // Post-process is required for branch instructions:
  //
  // - Need to assign a valid branch target. This is done by picking a random instruction label in
  //   this sequence and assigning to the branch instruction. All the non-atomic instructions
  //   will have a unique numeric label as the local branch target identifier.
  // - The atomic instruction streams don't have labels except for the first instruction. This is
  //   to avoid branching into an atomic instruction stream which breaks its atomicy. The
  //   definition of an atomic instruction stream here is a sequence of instructions which must be
  //   executed in-order.
  // - In this sequence, only forward branch is handled. The backward branch target is implemented
  //   in a dedicated loop instruction sequence. Randomly choosing a backward branch target could
  //   lead to dead loops in the absence of proper loop exiting conditions.
  //
  //----------------------------------------------------------------------------------------------
  virtual function void post_process_instr();
    int i;
    int label_idx;
    int branch_cnt;
    int unsigned branch_idx[];
    int branch_target[int] = '{default: 0};
    // Insert directed instructions, it's randomly mixed with the random instruction stream.
    foreach (directed_instr[i]) begin
      instr_stream.insert_instr_stream(directed_instr[i].instr_list);
    end
    // Assign an index for all instructions, these indexes won't change even a new instruction
    // is injected in the post process.
    foreach (instr_stream.instr_list[i]) begin
      instr_stream.instr_list[i].idx = label_idx;
      if (instr_stream.instr_list[i].has_label && !instr_stream.instr_list[i].atomic) begin
        if ((illegal_instr_pct > 0) && (instr_stream.instr_list[i].is_illegal_instr == 0)) begin
          // The illegal instruction generator always increase PC by 4 when resume execution, need
          // to make sure PC + 4 is at the correct instruction boundary.
          if (instr_stream.instr_list[i].is_compressed) begin
            if (i < instr_stream.instr_list.size()-1) begin
              if (instr_stream.instr_list[i+1].is_compressed) begin
                instr_stream.instr_list[i].is_illegal_instr =
                                       ($urandom_range(0, 100) < illegal_instr_pct);
              end
            end
          end else begin
            instr_stream.instr_list[i].is_illegal_instr =
                                       ($urandom_range(0, 100) < illegal_instr_pct);
          end
        end
        if ((hint_instr_pct > 0) && (instr_stream.instr_list[i].is_illegal_instr == 0)) begin
          if (instr_stream.instr_list[i].is_compressed) begin
            instr_stream.instr_list[i].is_hint_instr =
                                       ($urandom_range(0, 100) < hint_instr_pct);
          end
        end
        instr_stream.instr_list[i].label = $sformatf("%0d", label_idx);
        instr_stream.instr_list[i].is_local_numeric_label = 1'b1;
        label_idx++;
      end
    end
    // Generate branch target
    branch_idx = new[30];
    `DV_CHECK_STD_RANDOMIZE_WITH_FATAL(branch_idx,
                                       foreach(branch_idx[i]) {
                                         branch_idx[i] inside {[1:cfg.max_branch_step]};
                                       })
    while(i < instr_stream.instr_list.size()) begin
      if((instr_stream.instr_list[i].category == BRANCH) &&
        (!instr_stream.instr_list[i].branch_assigned) &&
        (!instr_stream.instr_list[i].is_illegal_instr)) begin
        // Post process the branch instructions to give a valid local label
        // Here we only allow forward branch to avoid unexpected infinite loop
        // The loop structure will be inserted with a separate routine using
        // reserved loop registers
        int branch_target_label;
        int branch_byte_offset;
        branch_target_label = instr_stream.instr_list[i].idx + branch_idx[branch_cnt];
        if (branch_target_label >= label_idx) begin
          branch_target_label = label_idx-1;
        end
        branch_cnt++;
        if (branch_cnt == branch_idx.size()) begin
          branch_cnt = 0;
          branch_idx.shuffle();
        end
        `uvm_info(get_full_name(),
                  $sformatf("Processing branch instruction[%0d]:%0s # %0d -> %0d",
                  i, instr_stream.instr_list[i].convert2asm(),
                  instr_stream.instr_list[i].idx, branch_target_label), UVM_HIGH)
        instr_stream.instr_list[i].imm_str = $sformatf("%0df", branch_target_label);
        // Below calculation is only needed for generating the instruction stream in binary format
        for (int j = i + 1; j < instr_stream.instr_list.size(); j++) begin
          branch_byte_offset = (instr_stream.instr_list[j-1].is_compressed) ?
                               branch_byte_offset + 2 : branch_byte_offset + 4;
          if (instr_stream.instr_list[j].label == $sformatf("%0d", branch_target_label)) begin
            instr_stream.instr_list[i].imm = branch_byte_offset;
            break;
          end else if (j == instr_stream.instr_list.size() - 1) begin
            `uvm_fatal(`gfn, $sformatf("Cannot find target label : %0d", branch_target_label))
          end
        end
        instr_stream.instr_list[i].branch_assigned = 1'b1;
        branch_target[branch_target_label] = 1;
      end
      // Remove the local label which is not used as branch target
      if(instr_stream.instr_list[i].has_label &&
         instr_stream.instr_list[i].is_local_numeric_label) begin
        int idx = instr_stream.instr_list[i].label.atoi();
        if(!branch_target[idx]) begin
          instr_stream.instr_list[i].has_label = 1'b0;
        end
      end
      i++;
    end
    `uvm_info(get_full_name(), "Finished post-processing instructions", UVM_HIGH)
  endfunction

  // Inject a jump instruction stream
  // This function is called by msp430_asm_program_gen with the target program label
  // The jump routine is implmented with an atomic instruction stream(msp430_jump_instr). Similar
  // to load/store instructions, JALR/JAL instructions also need a proper base address and offset
  // as the jump target.
  function void insert_jump_instr(string target_label, int idx);
    msp430_jump_instr jump_instr;
    jump_instr = msp430_jump_instr::type_id::create("jump_instr");
    jump_instr.target_program_label = target_label;
    if(!is_main_program)
      jump_instr.stack_exit_instr = instr_stack_exit.pop_stack_instr;
    jump_instr.cfg = cfg;
    jump_instr.label = label_name;
    jump_instr.idx = idx;
    jump_instr.use_jalr = is_main_program;
    `DV_CHECK_RANDOMIZE_FATAL(jump_instr)
    instr_stream.insert_instr_stream(jump_instr.instr_list);
    `uvm_info(get_full_name(), $sformatf("%0s -> %0s...done",
              jump_instr.jump.instr_name.name(), target_label), UVM_LOW)
  endfunction

  // Convert the instruction stream to the string format.
  // Label is attached to the instruction if available, otherwise attach proper space to make
  // the code indent consistent.
  virtual function void generate_instr_stream(bit no_label = 1'b0);
    string prefix, str;
    int i;
    instr_string_list = {};
    for(i = 0; i < instr_stream.instr_list.size(); i++) begin
      if(i == 0) begin
        if (no_label) begin
          prefix = format_string(" ", LABEL_STR_LEN);
        end else begin
          prefix = format_string($sformatf("%0s:", label_name), LABEL_STR_LEN);
        end
        instr_stream.instr_list[i].has_label = 1'b1;
      end else begin
        if(instr_stream.instr_list[i].has_label) begin
          prefix = format_string($sformatf("%0s:", instr_stream.instr_list[i].label),
                   LABEL_STR_LEN);
        end else begin
          prefix = format_string(" ", LABEL_STR_LEN);
        end
      end
      str = {prefix, instr_stream.instr_list[i].convert2asm()};
      instr_string_list.push_back(str);
    end
    // If PMP is supported, need to align <main> to a 4-byte boundary.
    // TODO(udi) - this might interfere with multi-hart programs,
    //             may need to specifically match hart0.
    if (msp430_instr_pkg::support_pmp && !uvm_re_match(uvm_glob_to_re("*main*"), label_name)) begin
      instr_string_list.push_front(".align 2");
    end
    insert_illegal_hint_instr();
    prefix = format_string($sformatf("%0d:", i), LABEL_STR_LEN);
    if(!is_main_program) begin
      generate_return_routine(prefix);
    end
  endfunction

  function void generate_return_routine(string prefix);
    string str;
    int i;
    msp430_instr_name_t jump_instr[$] = {JALR};
    bit rand_lsb = $urandom_range(0, 1);
    msp430_reg_t ra;
    `DV_CHECK_STD_RANDOMIZE_WITH_FATAL(ra,
                                       !(ra inside {cfg.reserved_regs});
                                       ra != ZERO;)
    // Randomly set lsb of the return address, JALR should zero out lsb automatically
    str = {prefix, $sformatf("addi x%0d, x%0d, %0d", ra, cfg.ra, rand_lsb)};
    instr_string_list.push_back(str);
    if (!cfg.disable_compressed_instr) begin
      jump_instr.push_back(C_JR);
      if (!(RA inside {cfg.reserved_regs})) begin
        jump_instr.push_back(C_JALR);
      end
    end
    i = $urandom_range(0, jump_instr.size() - 1);
    case (jump_instr[i])
      C_JALR : str = {prefix, $sformatf("c.jalr x%0d", ra)};
      C_JR   : str = {prefix, $sformatf("c.jr x%0d", ra)};
      JALR   : str = {prefix, $sformatf("jalr x%0d, x%0d, 0", ra, ra)};
      default: `uvm_fatal(`gfn, $sformatf("Unsupported jump_instr %0s", jump_instr[i]))
    endcase
    instr_string_list.push_back(str);
  endfunction

  function void insert_illegal_hint_instr();
    int bin_instr_cnt;
    int idx;
    string str;
    illegal_instr.init(cfg);
    bin_instr_cnt = instr_cnt * cfg.illegal_instr_ratio / 1000;
    if (bin_instr_cnt >= 0) begin
      `uvm_info(`gfn, $sformatf("Injecting %0d illegal instructions, ratio %0d/100",
                      bin_instr_cnt, cfg.illegal_instr_ratio), UVM_LOW)
      repeat (bin_instr_cnt) begin
        `DV_CHECK_RANDOMIZE_WITH_FATAL(illegal_instr,
                                       exception != kHintInstr;)
        str = {indent, $sformatf(".4byte 0x%s # %0s",
                       illegal_instr.get_bin_str(), illegal_instr.comment)};
               idx = $urandom_range(0, instr_string_list.size());
        instr_string_list.insert(idx, str);
      end
    end
    bin_instr_cnt = instr_cnt * cfg.hint_instr_ratio / 1000;
    if (bin_instr_cnt >= 0) begin
      `uvm_info(`gfn, $sformatf("Injecting %0d HINT instructions, ratio %0d/100",
                      bin_instr_cnt, cfg.illegal_instr_ratio), UVM_LOW)
      repeat (bin_instr_cnt) begin
        `DV_CHECK_RANDOMIZE_WITH_FATAL(illegal_instr,
                                       exception == kHintInstr;)
        str = {indent, $sformatf(".2byte 0x%s # %0s",
                       illegal_instr.get_bin_str(), illegal_instr.comment)};
        idx = $urandom_range(0, instr_string_list.size());
        instr_string_list.insert(idx, str);
      end
    end
  endfunction

endclass

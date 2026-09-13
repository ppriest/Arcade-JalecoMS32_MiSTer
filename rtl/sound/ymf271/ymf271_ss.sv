//============================================================================
//  The savestate bus interface the vendored YMF271 is written against, and
//  the four section indices it uses. MS32 has no savestates: ms32_sound ties
//  every instance's select off, so access() is never true and the engine's
//  savestate logic is constant.
//
//  ssbus_if is copied unchanged from Arcade-SeibuSPI_MiSTer rtl/savestates.sv
//  (commit fd25dd4), itself vendored from Arcade-IGSPGM_MiSTer:
//  Copyright (C) 2023 Martin Donlon, GPL v2 or later.
//  system_consts below is this project's subset of SeibuSPI's
//  rtl/system_consts.sv: the SSIDX_YMF_* values only.
//============================================================================

package system_consts;
	parameter int SSIDX_YMF_REGS = 11;
	parameter int SSIDX_YMF_PAR  = 12;
	parameter int SSIDX_YMF_ST   = 13;
	parameter int SSIDX_YMF_FB   = 14;
endpackage

interface ssbus_if();
    logic [63:0] data;
    logic [31:0] addr;
    logic [7:0] select;
    logic write;
    logic read;
    logic query;
    logic [63:0] data_out;
    logic ack;

    function logic access(int idx);
        return (select == idx[7:0]) & ~query & (read | write);
    endfunction

    task setup(int idx, input [31:0] count, int width);
        ack <= 0;
        if (select == idx[7:0]) begin
            if (query) begin
                data_out <= { idx[7:0], 22'b0, width[1:0], count };
                ack <= 1;
            end
        end
    endtask

    task read_response(int idx, input [63:0] dout);
        if (select == idx[7:0]) begin
            data_out <= dout;
            ack <= 1;
        end
    endtask

    task write_ack(int idx);
        if (select == idx[7:0]) begin
            ack <= 1;
        end
    endtask

    modport master(
        output data, addr, select, write, read, query,
        input data_out, ack
    );

    modport slave(
        input data, addr, select, write, read, query,
        output data_out, ack,
        import access,
        import setup,
        import read_response,
        import write_ack
    );
endinterface

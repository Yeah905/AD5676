module da_wave_send #(
    parameter integer NUM_CHANNELS = 6,      // Number of sequential DAC channels to update
    parameter integer LDAC_PULSE_CLKS = 16,  // System clock cycles to hold LDAC low
	parameter integer LDAC_DELAY_CLKS  = 2,  // Delay cycles before asserting LDAC low
    parameter integer ROM_ADDR_WIDTH = 3     // Address width for the waveform ROM (>= ceil(log2(NUM_CHANNELS)))
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     key_wave_filter,      // Start pulse (one clock wide) to launch an update
    output reg                      busy,       // High while a transfer is in progress

    // ROM interface
    output reg  [ROM_ADDR_WIDTH-1:0] rom_addr/*synthesis noprune*/,  // Address of the waveform sample
    input  wire [23:0]              rom_data/*synthesis keep*/,   // 24-bit frame fetched from ROM (command + address + data)

    // AD5676 interface
    output reg                      sync_n,
    output wire                     sclk,
    output reg                      sdin,
    output reg                      ldac_n
);

    localparam integer TOTAL_BITS = 24;

    // FSM states（有限状态机状态编码）
    localparam [2:0]
        ST_IDLE       = 3'd0,
        ST_FETCH      = 3'd1,
        ST_LOAD       = 3'd2,
        ST_SHIFT      = 3'd3,
        ST_SYNC_HIGH  = 3'd4,
        ST_NEXT       = 3'd5,
        ST_LDAC_PULSE = 3'd6,
        ST_DONE       = 3'd7;

    reg [2:0]  state;
    reg [2:0]  next_state;

    // 信号寄存器说明：
    // channel_idx 追踪当前写入的 DAC 通道（ROM 地址）
    // shift_reg    存放 24bit SPI 帧数据（包含命令+地址+数据），逐位输出
    // bits_remaining 剩余需要移出的位数，用于判断帧结束
    // sclk_phase   在 50MHz 主时钟下区分“高/低”半周期，确保按 SCLK 下降沿移位
    // ldac_cnt     控制 LDAC 低电平保持时间
    // start_d      用于检测 start 脉冲（沿检测）
    reg [ROM_ADDR_WIDTH-1:0] channel_idx;
    reg [TOTAL_BITS-1:0]     shift_reg;
    reg [5:0]                bits_remaining;
    reg [15:0]               ldac_cnt;
	reg [15:0]               ldac_delay_cnt;
	reg              		 key_wave_filter_d0 ;
	reg              		 key_wave_filter_d1 ;
//    reg                      start_d;
    reg                      sclk_phase;
    reg                      frame_done;

//    wire start_pulse = start & ~start_d;

	wire             key_wave_filter_neg;   //波形控制按键下降沿
	
    // 在发送阶段直接使用 50MHz 主时钟作为 SCLK，并在其他状态下强制为低电平
    assign sclk = (state == ST_SHIFT) ? clk : 1'b0;

	//抓取按键的下降沿
assign  key_wave_filter_neg = (~key_wave_filter_d0) & key_wave_filter_d1;

//为了抓取按键的下降沿，对按键信号打两拍
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        key_wave_filter_d0 <= 1'b1;
        key_wave_filter_d1 <= 1'b1;
    end
    else begin 
        key_wave_filter_d0 <= key_wave_filter;
        key_wave_filter_d1 <= key_wave_filter_d0;
    end
end
	
    // Synchronize start signal（start 同步捕获，形成一个周期的上升沿脉冲）
//    always @(posedge clk or negedge rst_n) begin
//        if (!rst_n) begin
//            start_d <= 1'b0;
//        end else begin
//            start_d <= start;
//        end
//    end

    // Sequential state transitions and counters
    // 中文说明：在 50MHz 时钟下根据当前状态更新输出与计数器，保证 SPI 时序和 LDAC 控制。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            channel_idx    <= {ROM_ADDR_WIDTH{1'b0}};
            bits_remaining <= 6'd0;
            shift_reg      <= {TOTAL_BITS{1'b0}};
            ldac_cnt       <= 16'd0;
            sync_n         <= 1'b1;
            sdin           <= 1'b0;
            ldac_n         <= 1'b1;
            busy           <= 1'b0;
            rom_addr       <= {ROM_ADDR_WIDTH{1'b0}};
            sclk_phase     <= 1'b0;
            frame_done     <= 1'b0;
        end else begin
           			
			if (state != ST_LDAC_PULSE && next_state == ST_LDAC_PULSE) begin
                ldac_delay_cnt <= LDAC_DELAY_CLKS;
            end else if (state == ST_LDAC_PULSE && ldac_delay_cnt != 16'd0) begin
                ldac_delay_cnt <= ldac_delay_cnt - 1'b1;
            end else if (state != ST_LDAC_PULSE) begin
                ldac_delay_cnt <= 16'd0;
            end
			
			state <= next_state;
			
            case (state)
                ST_IDLE: begin
                    // 空闲状态：等待 start 脉冲，保持总线空闲、LDAC 为高
                    sync_n <= 1'b1;
                    ldac_n <= 1'b1;
                    busy   <= 1'b0;
                    sclk_phase <= 1'b0;
                    frame_done <= 1'b0;
                    if (key_wave_filter_neg == 1) begin
                        busy        <= 1'b1;
                        channel_idx <= {ROM_ADDR_WIDTH{1'b0}};
                        rom_addr    <= {ROM_ADDR_WIDTH{1'b0}};
                    end
                end

                ST_FETCH: begin
                    // 访问 ROM，读取对应通道的 24bit 帧
                    rom_addr <= channel_idx;
                    frame_done <= 1'b0;
                end

                ST_LOAD: begin
                    // 捕获 ROM 数据并装入移位寄存器，同时拉低 SYNC 准备开始移位
                    shift_reg      <= rom_data;
                    bits_remaining <= TOTAL_BITS;
                    sync_n         <= 1'b0;
                    sdin           <= rom_data[TOTAL_BITS-1];
                    sclk_phase     <= 1'b0;
                    frame_done     <= 1'b0;
                end

                ST_SHIFT: begin
                    // 中文：50MHz 主时钟直接作为 SCLK。旧值 sclk_phase=1 表示刚经历高电平，即 SCLK 下降沿。
                    if (sclk_phase) begin
                        if (bits_remaining <= 6'd1) begin
                            bits_remaining <= 6'd0;
                            frame_done     <= 1'b1;  // 最后一个位已经传完
                        end else begin
                            bits_remaining <= bits_remaining - 1'b1;
                            shift_reg      <= {shift_reg[TOTAL_BITS-2:0], 1'b0};
                            sdin           <= shift_reg[TOTAL_BITS-2];
                        end
                    end else begin
                        // SCLK 上升沿前准备好当前位（保持 sdin 为当前 MSB）
                        sdin <= shift_reg[TOTAL_BITS-1];
                    end
                    sclk_phase <= ~sclk_phase;
                end

                ST_SYNC_HIGH: begin
                    // 完成一帧发送，释放 SYNC 并复位 SCLK/SDIN
                    sync_n <= 1'b1;
                    sdin   <= 1'b0;
                    sclk_phase <= 1'b0;
                    frame_done <= 1'b0;
                end

                ST_NEXT: begin
                    // 判断是否还有剩余通道需要写入
                    if (channel_idx < (NUM_CHANNELS - 1)) begin
                        channel_idx <= channel_idx + 1'b1;
                    end
                    frame_done <= 1'b0;
                end

/*                ST_LDAC_PULSE: begin
                    // 发送所有帧后，拉低 LDAC 一段时间，触发 DAC 同步更新
                    if (ldac_cnt == 16'd0) begin
                        ldac_n   <= 1'b0;
                        ldac_cnt <= LDAC_PULSE_CLKS;
                    end else if (ldac_cnt == 16'd1) begin
                        ldac_n   <= 1'b1;
                        ldac_cnt <= 16'd0;
                    end else begin
                        ldac_cnt <= ldac_cnt - 1'b1;
                    end
                    frame_done <= 1'b0;
                end
*/				
				ST_LDAC_PULSE: begin
                    // 发送所有帧后，先等待 LDAC_DELAY_CLKS 个周期再拉低 LDAC，然后保持 LDAC 低电平 LDAC_PULSE_CLKS 个周期
                    if (ldac_delay_cnt != 16'd0) begin
                        ldac_n   <= 1'b1;
                        ldac_cnt <= 16'd0;
                    end else if (ldac_cnt == 16'd0) begin
                        ldac_n   <= 1'b0;
                        ldac_cnt <= LDAC_PULSE_CLKS;
                    end else if (ldac_cnt == 16'd1) begin
                        ldac_n   <= 1'b1;
                        ldac_cnt <= 16'd0;
                    end else begin
                        ldac_cnt <= ldac_cnt - 1'b1;
                    end
                    frame_done <= 1'b0;
               end

                ST_DONE: begin
                    // 更新结束，回到空闲状态前的收尾
                    busy    <= 1'b0;
                    ldac_n  <= 1'b1;
                    sync_n  <= 1'b1;
                    sdin    <= 1'b0;
                    sclk_phase <= 1'b0;
                    frame_done <= 1'b0;
                end

                default: ;
            endcase
        end
    end

    // Next state logic
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (key_wave_filter_neg == 1)
                    next_state = ST_FETCH;
            end

            ST_FETCH: begin
                next_state = ST_LOAD;
            end

            ST_LOAD: begin
                next_state = ST_SHIFT;
            end

            ST_SHIFT: begin
                if (frame_done)
                    next_state = ST_SYNC_HIGH;
            end

            ST_SYNC_HIGH: begin
                next_state = ST_NEXT;
            end

            ST_NEXT: begin
                if (channel_idx < (NUM_CHANNELS - 1)) begin
                    next_state = ST_FETCH;
                end else begin
                    next_state = ST_LDAC_PULSE;
                end
            end

            ST_LDAC_PULSE: begin
                if (ldac_cnt == 16'd1)
                    next_state = ST_DONE;
            end

            ST_DONE: begin
                next_state = ST_IDLE;
            end

            default: begin
                next_state = ST_IDLE;
            end
        endcase
    end

endmodule

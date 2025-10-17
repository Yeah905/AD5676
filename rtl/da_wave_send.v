module da_wave_send(
    input                 clk            ,
    input                 rst_n          , //复位信号，低电平有效
   //消抖后的按键值
    input                 key_wave_filter, //波形控制按键消抖后的按键值
   //读rom
    input        [7:0]    rd_data        , //ROM读出的数据
    output  reg  [8:0]    rd_addr        , //读ROM地址
    //DA芯片接口                        
    output                da_clk         , //DAC驱动时钟
    output       [7:0]    da_data          //输出给DA的数据  
    );
	

	
endmodule
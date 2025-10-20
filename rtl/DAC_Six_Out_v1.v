//****************************************************************************************//
//AD5676同时输出6通道DAC，U1-U6
//****************************************************************************************//


module DAC_Six_Out_v1(
    input                 sys_clk     ,  //系统时钟
    input                 sys_rst_n   ,  //系统复位，低电平有效
    input                 key_wave    ,  //电压输出控制按键
    //DA芯片接口
    output                da_clk      ,  //DAC驱动时钟
	output				  ldac_n	  ,
	output				  sync_n	  ,
    output                sdin        //输出给DA的数据 
);

//parameter define
parameter  CNT_MAX = 22'd100_0000;      //50MHz时钟下计数20ms

//wire define 
wire             rst_n          ;  // 复位，低有效
wire             locked         ;  //PLL时钟锁定信号
wire             clk_25m       ;  //50MHz时钟
wire    [2:0]    rd_addr        ;  //ROM读地址
wire    [23:0]    rom_data        ;  //ROM读出的数据
wire             key_wave_filter;  //波形控制按键消抖后的按键值

//通过系统复位信号和PLL时钟锁定信号来产生一个新的复位信号
assign   rst_n = sys_rst_n & locked;

//PLL IP核
pll	u_pll (
    .areset             ( ~sys_rst_n ),
    .inclk0             ( sys_clk ),
    .c0                 ( clk_25m ),
    .locked             ( locked )
    );

//ROM存储波形
rom	u_rom (
    .address            ( rd_addr ),
    .clock              ( clk_25m ),
    .q                  ( rom_data )
    );

//例化按键消抖模块
key_debounce #(
    .CNT_MAX            (CNT_MAX        ))
u_key_wave_debounce(
    .sys_clk            (clk_25m        ),
    .sys_rst_n          (rst_n          ),
    .key                (key_wave       ),
    .key_filter         (key_wave_filter)
    );

//DA数据发送
da_wave_send u_da_wave_send(
    .clk                (clk_25m        ),
    .rst_n              (rst_n          ),
    .key_wave_filter    (key_wave_filter),
    .rom_data           (rom_data       ),
    .rom_addr           (rd_addr        ),
    .sclk               (da_clk         ),
	.sync_n				(sync_n			),
	.ldac_n				(ldac_n			),
    .sdin               (sdin           )
    );
	
endmodule

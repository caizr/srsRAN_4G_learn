# PDSCH ENCODE流程
参考链接: https://www.sharetechnote.com/html/SDR_srsLTE_Example_Pdsch_enodeb.html
运行参数:
-o "pdsch_out.txt" -n 1 -m 1 -p 50 (输出文件、产生的帧数、MCS、RB数量)
## base_init流程
```c++
static void base_init()
{
  int i;

  /* 配置传输模式 */
  /* Configure cell and PDSCH in function of the transmission mode */
  switch (transmission_mode) {
    case SRSRAN_TM1: // TM1: 单天线传输
      cell.nof_ports = 1;
      break;
    case SRSRAN_TM2: // 发送分集
    case SRSRAN_TM3:
    case SRSRAN_TM4:
      cell.nof_ports = 2;
      break;
    default:
      ERROR("Transmission mode %d not implemented or invalid", transmission_mode);
      exit(-1);
  }
```
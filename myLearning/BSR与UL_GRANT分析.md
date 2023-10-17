# BSR与UL_GRANT分析
运行环境后, ping 172.16.0.2 ， UE会持续发送上行数据。MAC层在每次TTI时会运行BSR程序:
```C++
void mac::run_tti(const uint32_t tti)
{
  logger.set_context(tti);

  /* Warning: Here order of invocation of procedures is important!! */

  // Step all procedures (must follow this order)
  Debug("Running MAC tti=%d", tti);
  mux_unit.step();
  // 运行BSR
  bsr_procedure.step(tti);
  sr_procedure.step(tti);
  phr_procedure.step();
  ra_procedure.step(tti);
  ra_procedure.update_rar_window(ra_window);

  // Count TTI for metrics
  std::lock_guard<std::mutex> lock(metrics_mutex);
  for (uint32_t i = 0; i < SRSRAN_MAX_CARRIERS; i++) {
    metrics[i].nof_tti++;
  }
}
// proc_bsr.cc 
void bsr_proc::step(uint32_t tti)
{
  std::lock_guard<std::mutex> lock(mutex);

  if (!initiated) {
    return;
  }
  // 检查RLC是否有更新数据
  update_new_data();

  // Regular BSR triggered if new data arrives or channel with high priority has new data
  // 先不讨论什么时候发送SR
  if (check_new_data() || check_highest_channel()) {
    logger.debug("BSR:   Triggering Regular BSR tti=%d", tti);
    set_trigger(REGULAR);
  }

  update_old_buffer();
}
```
这里先不对SR的时机做具体讨论。上行有数据发送时，会调用:
```C++
bool bsr_proc::need_to_send_bsr_on_ul_grant(uint32_t grant_size, uint32_t total_data, bsr_t* bsr)
{
  std::lock_guard<std::mutex> lock(mutex);

  bool send_bsr = false;
  if (triggered_bsr_type == PERIODIC || triggered_bsr_type == REGULAR) {
    // All triggered BSRs shall be cancelled in case the UL grant can accommodate all pending data
    if (grant_size >= total_data) {
      triggered_bsr_type = NONE;
    } else {
      // grant不足时才会发送BSR信息
      send_bsr = generate_bsr(bsr, grant_size);
    }
  }

  // Cancel SR if an Uplink grant is received
  logger.debug("BSR:   Cancelling SR procedure due to uplink grant");
  sr->reset();

  // Restart or Start ReTX timer upon indication of a grant
  if (timer_retx.duration()) {
    timer_retx.run();
    logger.debug("BSR:   Started retxBSR-Timer");
  }
  return send_bsr;
}
```
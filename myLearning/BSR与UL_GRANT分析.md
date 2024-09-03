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
查看need_to_send_bsr_on_ul_grant的调用堆栈：
```HTML
mux::pdu_get_nolock
mux::pdu_get
ul_harq_entity::ul_harq_process::new_grant_ul
ul_harq_entity::new_grant_ul
mac::new_grant_ul
ue_stack_lte::new_grant_ul
cc_worker::work_ul
sf_worker::work_imp
thread_pool::worker::run_thread()
```
注意看need_to_send_bsr_on_ul_grant的前两个参数，只有grant_size小于total_data时会generate_bsr。现在探究这个grant_size是从哪儿来的：
先看调用该函数的地方:
```C++
bool regular_bsr = bsr_procedure->need_to_send_bsr_on_ul_grant(pdu_msg.rem_size(), total_pending_data, &bsr);
// pdu_msg定义:
srsran::sch_pdu pdu_msg;
class sch_pdu : public pdu<sch_subh>
{
    //......
    int      rem_size();
    //......
protected:
  // ......
  uint32_t              pdu_len;
  uint32_t              rem_len;
  // rem_len 只有在这里会赋值:
  virtual void init_(byte_buffer_t* buffer_tx_, uint32_t pdu_len_bytes, bool is_ulsch)
  {
    nof_subheaders = 0;
    pdu_len        = pdu_len_bytes;
    rem_len        = pdu_len;
    //......
  }
  // 调用init_的地方:
  void init_rx(uint32_t pdu_len_bytes, bool is_ulsch = false) { init_(NULL, pdu_len_bytes, is_ulsch); }

  void init_tx(byte_buffer_t* buffer, uint32_t pdu_len_bytes, bool is_ulsch = false)
  {
    init_(buffer, pdu_len_bytes, is_ulsch);
  }
}
```
合理猜测，需要发送上行数据的时候会调用init_tx，读取grant。在init_tx处打断点，查看其调用堆栈：
```C++
init_tx
mux::pdu_get_nolock(srsran::byte_buffer_t* payload, uint32_t pdu_sz)
uint8_t* mux::pdu_get(srsran::byte_buffer_t* payload, uint32_t pdu_sz)
......
```
和need_to_send_bsr_on_ul_grant是一样的堆栈。实际上就是在调用need_to_send_bsr_on_ul_grant之前init_tx。pdu_sz一直溯源，可以找到
```C++
cc_worker::work_ul(srsran_uci_data_t* uci_data){
    //......
    // Fill MAC dci
    ul_phy_to_mac_grant(&ue_ul_cfg.ul_cfg.pusch.grant, &dci_ul, pid, ul_grant_available, &ul_mac_grant);
    // ul_mac_grant.tb.tbs就是grant size
    phy->stack->new_grant_ul(cc_idx, ul_mac_grant, &ul_action);
    //......
}
```
注释中提到，ul_mac_grant.tb.tbs就是grant size，而ul_mac_grant.tb.tbs是在上一行ul_phy_to_mac_grant中赋值的:
```C++
void cc_worker::ul_phy_to_mac_grant(srsran_pusch_grant_t*                         phy_grant,
                                    srsran_dci_ul_t*                              dci_ul,
                                    uint32_t                                      pid,
                                    bool                                          ul_grant_available,
                                    srsue::mac_interface_phy_lte::mac_grant_ul_t* mac_grant)
{
  if (mac_grant->phich_available && !dci_ul->rnti) {
    mac_grant->rnti = phy->stack->get_ul_sched_rnti(CURRENT_TTI);
  } else {
    mac_grant->rnti = dci_ul->rnti;
  }
  mac_grant->tb.ndi         = dci_ul->tb.ndi;
  mac_grant->tb.ndi_present = ul_grant_available;
  mac_grant->tb.tbs         = phy_grant->tb.tbs / (uint32_t)8; // 这里赋值
  mac_grant->tb.rv          = phy_grant->tb.rv;
  mac_grant->pid            = pid;
  mac_grant->is_rar         = dci_ul->format == SRSRAN_DCI_FORMAT_RAR;
  mac_grant->tti_tx         = CURRENT_TTI_TX;
}
```
所以grant size来源于ue_ul_cfg.ul_cfg.pusch.grant, 搜索可能对ue_ul_cfg修改的地方，发现有两处：
```C++
// 1.
cc_worker::work_ul(srsran_uci_data_t* uci_data){
    // ......
    if (srsran_ue_ul_dci_to_pusch_grant(&ue_ul, &sf_cfg_ul, &ue_ul_cfg, &dci_ul, &ue_ul_cfg.ul_cfg.pusch.grant))
    // ......
}

// 2.
void cc_worker::set_config_nolock(const srsran::phy_cfg_t& phy_cfg)
{
  // Save configuration
  ue_dl_cfg.cfg    = phy_cfg.dl_cfg;
  ue_ul_cfg.ul_cfg = phy_cfg.ul_cfg;

  phy->set_pdsch_cfg(&ue_dl_cfg.cfg.pdsch);
}
```
验证过后， 第一处会对前后ue_ul_cfg中的ul grant size会有变动。该函数以下部分有赋值grant size:
```C++
int srsran_ue_ul_dci_to_pusch_grant(srsran_ue_ul_t*       q,
                                    srsran_ul_sf_cfg_t*   sf,
                                    srsran_ue_ul_cfg_t*   cfg,
                                    srsran_dci_ul_t*      dci,
                                    srsran_pusch_grant_t* grant)
{
  // Convert DCI to Grant
  if (srsran_ra_ul_dci_to_grant(&q->cell, sf, &cfg->ul_cfg.hopping, dci, grant)) {
    return SRSRAN_ERROR;
  }
  // ......
}
```
看注释也能看出来，UL GRANT是在DCI 0中体现的，印证注释做的事情。继续看:
```C++
// srsran_ra_ul_dci_to_grant->ul_fill_ra_mcs
// tb.tbs就是grant size
static void ul_fill_ra_mcs(srsran_ra_tb_t* tb, srsran_ra_tb_t* last_tb, uint32_t L_prb, bool cqi_request)
{
  // 8.6.2 First paragraph
  if (tb->mcs_idx <= 28) {
    /* Table 8.6.1-1 on 36.213 */
    if (tb->mcs_idx < 11) {
      tb->mod = SRSRAN_MOD_QPSK;
      tb->tbs = srsran_ra_tbs_from_idx(tb->mcs_idx, L_prb);
    } else if (tb->mcs_idx < 21) {
      tb->mod = SRSRAN_MOD_16QAM;
      tb->tbs = srsran_ra_tbs_from_idx(tb->mcs_idx - 1, L_prb);
    } else if (tb->mcs_idx < 29) {
      tb->mod = SRSRAN_MOD_64QAM;
      tb->tbs = srsran_ra_tbs_from_idx(tb->mcs_idx - 2, L_prb);
    } else {
      ERROR("Invalid MCS index %d", tb->mcs_idx);
    }
  } else if (tb->mcs_idx == 29 && cqi_request && L_prb <= 4) {
    // 8.6.1 and 8.6.2 36.213 second paragraph
    tb->mod = SRSRAN_MOD_QPSK;
    tb->tbs = 0;
    tb->rv  = 1;
  } else if (tb->mcs_idx >= 29) {
    // Else use last TBS/Modulation and use mcs to obtain rv_idx
    tb->tbs = last_tb->tbs;
    tb->mod = last_tb->mod;
    tb->rv  = tb->mcs_idx - 28;
  }
}
// srsran_ra_tbs_from_idx 根据mcs_idx计算grantsize
int srsran_ra_tbs_from_idx(uint32_t tbs_idx, uint32_t n_prb)
{
  if (tbs_idx < SRSRAN_RA_NOF_TBS_IDX && n_prb > 0 && n_prb <= SRSRAN_MAX_PRB) {
    return tbs_table[tbs_idx][n_prb - 1];
  } else {
    return SRSRAN_ERROR;
  }
}
```
至此，找到了UL GRANT赋值的地方。DCI的来源还需要进一步分析。
## DCI来源分析
还是cc_worker::work_ul函数，DCI的获取在此:
```C++
bool cc_worker::work_ul(srsran_uci_data_t* uci_data)
{
    //......
    bool ul_grant_available = phy->get_ul_pending_grant(&sf_cfg_ul, cc_idx, &pid, &dci_ul);
    //......
}
// phy_common.cc
bool phy_common::get_ul_pending_grant(srsran_ul_sf_cfg_t* sf, uint32_t cc_idx, uint32_t* pid, srsran_dci_ul_t* dci)
{
  std::lock_guard<std::mutex> lock(pending_ul_grant_mutex);
  bool                        ret           = false;
  pending_ul_grant_t&         pending_grant = pending_ul_grant[cc_idx][sf->tti];

  if (pending_grant.enable) {
    Debug("Reading grant sf->tti=%d idx=%d", sf->tti, TTIMOD(sf->tti));
    if (pid) {
      *pid = pending_grant.pid;
    }
    // 这里获取DCI
    if (dci) {
      *dci = pending_grant.dci;
    }
    pending_grant.enable = false;
    ret                  = true;
  }

  return ret;
}
```
pending_grant的赋值进行溯源，是在set_ul_pending_grant中获取的:
```C++
void phy_common::set_ul_pending_grant(srsran_dl_sf_cfg_t* sf, uint32_t cc_idx, srsran_dci_ul_t* dci)
{
  std::lock_guard<std::mutex> lock(pending_ul_grant_mutex);

  // Calculate PID for this SF->TTI
  uint32_t            pid           = ul_pidof(tti_pusch_gr(sf), &sf->tdd_config);
  pending_ul_grant_t& pending_grant = pending_ul_grant[cc_idx][tti_pusch_gr(sf)];

  if (!pending_grant.enable) {
    pending_grant.pid    = pid;
    pending_grant.dci    = *dci;
    pending_grant.enable = true;
    Debug("Set ul pending grant for sf->tti=%d current_tti=%d, pid=%d", tti_pusch_gr(sf), sf->tti, pid);
  } else {
    Info("set_ul_pending_grant: sf->tti=%d, cc=%d already in use", sf->tti, cc_idx);
  }
}
```
查看set_ul_pending_grant的堆栈:
```C++
phy_common::set_ul_pending_grant(srsran_dl_sf_cfg_t* sf, uint32_t cc_idx, srsran_dci_ul_t* dci)
cc_worker::decode_pdcch_ul()
cc_worker::work_dl_regular()
sf_worker::work_imp()
```
从这里看出，DCI是从PDCCH中得到，分析decode_pdcch_ul()中获取DCI是调用srsran_ue_dl_find_ul_dci:
```C++
// ue_dl.c
int srsran_ue_dl_find_ul_dci(srsran_ue_dl_t*     q,
                             srsran_dl_sf_cfg_t* sf,
                             srsran_ue_dl_cfg_t* dl_cfg,
                             uint16_t            rnti,
                             srsran_dci_ul_t     dci_ul[SRSRAN_MAX_DCI_MSG])
{
  srsran_dci_msg_t dci_msg[SRSRAN_MAX_DCI_MSG];
  uint32_t         nof_msg = 0;

  if (rnti) {
    // Copy the messages found in the last call to srsran_ue_dl_find_dl_dci()
    nof_msg = SRSRAN_MIN(SRSRAN_MAX_DCI_MSG, q->pending_ul_dci_count);
    memcpy(dci_msg, q->pending_ul_dci_msg, sizeof(srsran_dci_msg_t) * nof_msg);
    q->pending_ul_dci_count = 0;

    // Unpack DCI messages
    for (uint32_t i = 0; i < nof_msg; i++) {
      if (srsran_dci_msg_unpack_pusch(&q->cell, sf, &dl_cfg->cfg.dci, &dci_msg[i], &dci_ul[i])) {
        ERROR("Unpacking UL DCI");
        return SRSRAN_ERROR;
      }
    }

    return nof_msg;

  } else {
    return 0;
  }
}
```
// dci.cc srsran_dci_msg_unpack_pusch:
int srsran_dci_msg_unpack_pusch(srsran_cell_t*      cell,
                                srsran_dl_sf_cfg_t* sf,
                                srsran_dci_cfg_t*   cfg,
                                srsran_dci_msg_t*   msg,
                                srsran_dci_ul_t*    dci)
{
  // Initialize DCI
  bzero(dci, sizeof(srsran_dci_ul_t));

  dci->rnti     = msg->rnti;
  dci->location = msg->location;
  dci->format   = msg->format;

  srsran_dci_cfg_t _dci_cfg;
  if (!cfg) {
    ZERO_OBJECT(_dci_cfg);
    cfg = &_dci_cfg;
  }

#if SRSRAN_DCI_HEXDEBUG
  dci->hex_str[0] = '\0';
  srsran_vec_sprint_hex(dci->hex_str, sizeof(dci->hex_str), msg->payload, msg->nof_bits);
  dci->nof_bits = msg->nof_bits;
#endif /* SRSRAN_DCI_HEXDEBUG */

  return dci_format0_unpack(cell, sf, cfg, msg, dci);
}
// dci_format0_unpack
static int dci_format0_unpack(srsran_cell_t*      cell,
                              srsran_dl_sf_cfg_t* sf,
                              srsran_dci_cfg_t*   cfg,
                              srsran_dci_msg_t*   msg,
                              srsran_dci_ul_t*    dci)
{
  /* pack bits */
  uint8_t* y = msg->payload;
  uint32_t n_ul_hop;

  if (cfg->cif_enabled) {
    dci->cif         = srsran_bit_pack(&y, 3);
    dci->cif_present = true;
  }

  if (*y++ != 0) {
    INFO("DCI message is Format1A");
    return SRSRAN_ERROR;
  }

  // Update DCI format
  msg->format = SRSRAN_DCI_FORMAT0;

  if (*y++ == 0) {
    dci->freq_hop_fl = SRSRAN_RA_PUSCH_HOP_DISABLED;
    n_ul_hop         = 0;
  } else {
    if (cell->nof_prb < 50) {
      n_ul_hop         = 1; // Table 8.4-1 of 36.213
      dci->freq_hop_fl = *y++;
    } else {
      n_ul_hop         = 2; // Table 8.4-1 of 36.213
      dci->freq_hop_fl = y[0] << 1 | y[1];
      y += 2;
    }
  }
  /* unpack RIV according to 8.1 of 36.213 */
  uint32_t riv         = srsran_bit_pack(&y, riv_nbits(cell->nof_prb) - n_ul_hop);
  dci->type2_alloc.riv = riv;

  /* unpack MCS according to 8.6 of 36.213 */
  dci->tb.mcs_idx = srsran_bit_pack(&y, 5);
  dci->tb.ndi     = *y++ ? true : false;

  // TPC command for scheduled PUSCH
  dci->tpc_pusch = srsran_bit_pack(&y, 2);

  // Cyclic shift for DMRS
  dci->n_dmrs = srsran_bit_pack(&y, 3);

  // TDD fields
  if (IS_TDD_CFG0) {
    dci->ul_idx = srsran_bit_pack(&y, 2);
    dci->is_tdd = true;
  } else if (IS_TDD) {
    dci->dai    = srsran_bit_pack(&y, 2);
    dci->is_tdd = true;
  }

  // CQI request
  if (cfg->multiple_csi_request_enabled && !cfg->is_not_ue_ss) {
    dci->multiple_csi_request_present = true;
    dci->multiple_csi_request         = srsran_bit_pack(&y, 2);
  } else {
    dci->cqi_request = *y++ ? true : false;
  }

  // SRS request
  if (cfg->srs_request_enabled && !cfg->is_not_ue_ss) {
    dci->srs_request_present = true;
    dci->srs_request         = *y++ ? true : false;
  }

  if (cfg->ra_format_enabled) {
    dci->ra_type_present = true;
    dci->ra_type         = *y++ ? true : false;
  }

  return SRSRAN_SUCCESS;
}
```

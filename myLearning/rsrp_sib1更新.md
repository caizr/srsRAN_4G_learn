# RSRP SIB1 更新
## 前置
在cell_select.puml中可以看出, rrc.cell_select_complete之后，state置为wait_measurement，等待下一次tti，rrc::cell_search_proc::step()
进入step_wait_measurement()，该函数首先会一直检查serving_cell的rsrp正常：
```c++
if (not std::isnormal(rrc_ptr->meas_cells.serving_cell().get_rsrp())) {
  return proc_outcome_t::yield;
}
```
只有服务小区测量得到rsrp后，才会进行后续的工作。
## RSRP更新
前面提到get_rsrp方法，相应的自然有set_rsrp方法，查询调用set_rsrp的地方，可以发现调用的地方在rrc.cc:
```c++
void rrc::process_new_cell_meas(const std::vector<phy_meas_t>& meas)
{
    // ...
    const std::function<void(meas_cell_eutra&, const phy_meas_t&)> filter = [this](meas_cell_eutra&  c,
                                                                                 const phy_meas_t& m) {
    c.set_rsrp(measurements->rsrp_filter(m.rsrp, c.get_rsrp()));
    c.set_rsrq(measurements->rsrq_filter(m.rsrq, c.get_rsrq()));
    c.set_cfo(m.cfo_hz);
  };
    // ...
}
```
继续溯源，发现process_cell_meas()调用了process_new_cell_meas，run_tti调用了发现process_cell_meas()。每次TTI都会更新rsrp（如果条件
成立），显然这不是测量并更新rsrp的地方。观察process_cell_meas，发现只有cell_meas_q有数据时，才会调用process_new_cell_meas。
找到cell_meas_q添加数据的地方：
```c++
void rrc::new_cell_meas(const std::vector<phy_meas_t>& meas)
{
  cell_meas_q.push(meas);
}
```
查看其堆栈，总结调用流程如下:
```c++
(sf_worker) thread_pool::worker::run_thread()   ->
sf_worker::work_imp()                           ->
sf_worker::update_measurements()                ->
ue_stack_lte::new_cell_meas()
```
sf_worker处理物理层的每个子帧，其bring up流程可以参考: https://blog.csdn.net/qq_15026719/article/details/126955062

## SIB1更新
服务小区更新rsrp之后，step_wait_measurement会进入下一个环节，启动si_acquirer（这里暂时没有参开研究机制）。并将state置为state_t::si_acquire，
之后马上再次运行rrc::cell_search_proc::step()，其实进入到step_si_acquire()环节。

step_si_acquire()返回success之后，plmn_search_proc::step()会进入到下一个环节:
```c++
proc_outcome_t rrc::plmn_search_proc::step()
{
  std::cout<<"rrc::plmn_search_proc::step()"<<std::endl;
  // 在step_si_acquire()返回success之前，每次都会返回yield
  if (rrc_ptr->cell_searcher.run()) {
    // wait for new TTI
    return proc_outcome_t::yield;
  }
  if (cell_search_fut.is_error() or cell_search_fut.value()->found == cell_search_ret_t::ERROR) {
    // stop search
    nof_plmns = -1;
    Error("Failed due to failed cell search sub-procedure");
    return proc_outcome_t::error;
  }

  if (cell_search_fut.value()->found == cell_search_ret_t::CELL_FOUND) {
    if (rrc_ptr->meas_cells.serving_cell().has_sib1()) {
      // Save PLMN and TAC to NAS
      for (uint32_t i = 0; i < rrc_ptr->meas_cells.serving_cell().nof_plmns(); i++) {
        if (nof_plmns < nas_interface_rrc::MAX_FOUND_PLMNS) {
          found_plmns[nof_plmns].plmn_id = rrc_ptr->meas_cells.serving_cell().get_plmn(i);
          found_plmns[nof_plmns].tac     = rrc_ptr->meas_cells.serving_cell().get_tac();
          nof_plmns++;
        } else {
          Error("No more space for plmns (%d)", nof_plmns);
        }
      }
    } else {
      Error("SIB1 not acquired");
    }
  }

  if (cell_search_fut.value()->last_freq == cell_search_ret_t::NO_MORE_FREQS) {
    Info("completed PLMN search");
    return proc_outcome_t::success;
  }

  if (not rrc_ptr->cell_searcher.launch(&cell_search_fut)) {
    Error("Failed due to fail to init cell search...");
    return proc_outcome_t::error;
  }

  // run again
  return step();
}
```
## 后续工作
set_sib1后续接si_acquirer.trigger。mac::process_pdus()将任务放进列表。
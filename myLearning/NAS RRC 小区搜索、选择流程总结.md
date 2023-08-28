# 从nas层开始
run_tti()在每次tti的时候检查状态:
```c++
void nas::run_tti()
{
  // Process PLMN selection ongoing procedures
  callbacks.run();

  // Transmit initiating messages if necessary
  switch (state.get_state()) {
    case emm_state_t::state_t::deregistered:
      // TODO Make sure cell selection is finished after transitioning from another state (if required)
      // Make sure the RRC is finished transitioning to RRC Idle
      if (reattach_timer.is_running()) {
        logger.debug("Waiting for re-attach timer to expire to attach again.");
        return;
      }
      switch (state.get_deregistered_substate()) {
        case emm_state_t::deregistered_substate_t::plmn_search:
          // 开机的时候会从这里运行
          start_plmn_selection_proc();     
          break;
          // 小区选择完成之后， 为normal_service(有待确认)
        case emm_state_t::deregistered_substate_t::normal_service:
        case emm_state_t::deregistered_substate_t::attach_needed:
          start_attach_request(srsran::establishment_cause_t::mo_data);    
          break;
        case emm_state_t::deregistered_substate_t::attempting_to_attach:
          logger.debug("Attempting to attach");
        default:
          break;
      }
    case emm_state_t::state_t::registered:
      break;
    case emm_state_t::state_t::deregistered_initiated:
      logger.debug("UE detaching...");
      break;
    default:
      break;
  }
}
```

nas开始小区选择:
```c++
// 首先看plmn_searcher的定义:
// proc_t 在RRC中经常看到, 有init(), step(), react() ......
srsran::proc_t<plmn_search_proc> plmn_searcher;

void nas::start_plmn_selection_proc()
{
  logger.debug("Attempting to select PLMN");
  if (plmn_searcher.is_idle()) {
    logger.info("No PLMN selected. Starting PLMN Selection...");
    if (not plmn_searcher.launch()) {
      logger.error("Error starting PLMN selection");
      return;
    }
  }
}
// plmn_searcher.launch() 会运行plmn_search_proc的init():
proc_outcome_t nas::plmn_search_proc::init()
{
  // start RRC PLMN selection
  if (not nas_ptr->rrc->plmn_search()) {
    ProcError("ProcError while searching for PLMNs");
    return proc_outcome_t::error;
  }

  ProcInfo("Starting...");
  return proc_outcome_t::yield;
}
// rrc中的plmn_search:
bool rrc::plmn_search()
{
  if (not plmn_searcher.launch()) {
    logger.error("Unable to initiate PLMN search");
    return false;
  }
  std::cout<<"rrc::plmn_search add_proc "<<std::endl;
  callback_list.add_proc(plmn_searcher);
  return true;
}
```

可以看到，RRC中，callback_list添加了plmn_searcher:
callback_list添加了plmn_searcher，plmn_searcher的定义如下:
``` C++
srsran::proc_t<plmn_search_proc>     plmn_searcher;
// proc_t 的定义
template <class T, typename ResultType = void>
class proc_t : public proc_base_t
{
  std::unique_ptr<T>           proc_ptr;
  bool launch(Args&&... args) // 调用proc_ptr中的init()
  //......
}
// proc_base_t的定义:
class proc_base_t
{
  bool run() // 调用proc_ptr中的step()
  //......
}
```
在RRC每次TTI都会运行callback_list中的函数:
```c++
void rrc::run_tti()
{
  callback_list.run();
  //......
}
// run()的定义:
void run()
{
  // Calls run for all callbacks. Remove the ones that have finished. The proc dtor is called.
  proc_list.remove_if([](proc_obj_t& elem) { return not elem->run(); });
}
```
elem->run()就是在运行proc_base_t中的run(), 只有proc_ptr中的step()返回success时, 才会在callback_list中清除add_proc添加的成员. 返回success的语句如下:
```c++
proc_outcome_t rrc::plmn_search_proc::step()
{
  std::cout<<"rrc::plmn_search_proc::step()"<<std::endl;
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
    return proc_outcome_t::success;    // <<=================这里返回success
  }

  if (not rrc_ptr->cell_searcher.launch(&cell_search_fut)) {
    Error("Failed due to fail to init cell search...");
    return proc_outcome_t::error;
  }

  // run again
  return step();
}
```

也就是说只有搜索完所有配置好的频点, 才会结束.

# RRC plmn_searcher在返回success时的动作:
先看看调用rrc::plmn_search_proc::step()的地方: (就是proc_base_t中的run)
```C++
bool run()
{
if (is_busy()) {
    proc_outcome_t outcome = step();
    handle_outcome(outcome);
}
return is_busy();
}
// outcome为success:
void handle_outcome(proc_outcome_t outcome)
{
    if (outcome == proc_outcome_t::error or outcome == proc_outcome_t::success) {
        bool success = outcome == proc_outcome_t::success;
        run_then(success);
    }
}
// run_then的定义
void run_then(bool is_success) final
{
    proc_state = proc_status_t::idle;
    proc_result_type result;
    // update result state
    if (is_success) { 
      result.extract_val(*proc_ptr);
    } else {
      result.set_error();
    }
    // propagate proc_result to future if it exists, and release future
    if (future_result != nullptr) {
      *future_result = result;
      future_result.reset();
    }
    // call T::then() if it exists
    proc_detail::optional_then(proc_ptr.get(), &result);
    // signal continuations
    complete_callbacks(std::move(result));
    // back to inactive
    proc_detail::optional_clear(proc_ptr.get());
}
// proc_detail::optional_then(proc_ptr.get(), &result) 会运行then:
auto optional_then(T* obj, const ProcResult* result) -> decltype(obj->then(*result))
{
  obj->then(*result);
}
// then的定义：
void rrc::plmn_search_proc::then(const srsran::proc_state_t& result) const
{
  // on cleanup, call plmn_search_completed
  if (result.is_success()) { // success
    Info("completed with success");
    rrc_ptr->nas->plmn_search_completed(found_plmns, nof_plmns);
  } else {
    Error("PLMN Search completed with an error");
    rrc_ptr->nas->plmn_search_completed(nullptr, -1);
  }
}
```
可以看到，又会返回运行nas的plmn_search_completed:
```C++
void nas::plmn_search_completed(const found_plmn_t found_plmns[MAX_FOUND_PLMNS], int nof_plmns)
{
  // 注意这是nas的plmn_searcher不是rrc的plmn_searcher
  plmn_searcher.trigger(plmn_search_proc::plmn_search_complete_t(found_plmns, nof_plmns));
}
// trigger的定义如下:
template <class Event>
bool trigger(Event&& e)
{
    if (is_busy()) {
      proc_outcome_t outcome = proc_ptr->react(std::forward<Event>(e));
      handle_outcome(outcome);
    }
    return is_busy();
}
// 说明trigger会运行nas::plmn_search_proc中的react
```
react具体的行为如下:
```C++
proc_outcome_t nas::plmn_search_proc::react(const plmn_search_complete_t& t)
{
  // ......
  // Save PLMNs
  nas_ptr->known_plmns.clear();
  for (int i = 0; i < t.nof_plmns; i++) {
    nas_ptr->known_plmns.push_back(t.found_plmns[i].plmn_id);
    ProcInfo("Found PLMN:  Id=%s, TAC=%d", t.found_plmns[i].plmn_id.to_string().c_str(), t.found_plmns[i].tac);
    srsran::console("Found PLMN:  Id=%s, TAC=%d\n", t.found_plmns[i].plmn_id.to_string().c_str(), t.found_plmns[i].tac);
  }
  // plmn选择
  nas_ptr->select_plmn();

  // Select PLMN in request establishment of RRC connection
  if (nas_ptr->state.get_state() != emm_state_t::state_t::deregistered and
      nas_ptr->state.get_deregistered_substate() != emm_state_t::deregistered_substate_t::normal_service) {
    ProcError("PLMN is not selected because no suitable PLMN was found");
    return proc_outcome_t::error;
  }

  // 这里只是告诉rrc plmn选好了并打印LOG
  nas_ptr->rrc->plmn_select(nas_ptr->current_plmn);

  return proc_outcome_t::success;
}

// nas_ptr->select_plmn()
void nas::select_plmn()
{
  logger.debug("Selecting PLMN from list of known PLMNs.");
  // ......
  // First find if Home PLMN is available
  for (const srsran::plmn_id_t& known_plmn : known_plmns) {
    if (known_plmn == home_plmn) {
      logger.info("Selecting Home PLMN Id=%s", known_plmn.to_string().c_str());
      current_plmn = known_plmn;
      state.set_deregistered(emm_state_t::deregistered_substate_t::normal_service);
      return;
    }
  }

  // If not, select the first available PLMN
  if (not known_plmns.empty()) {
    std::string debug_str = "Could not find Home PLMN Id=" + home_plmn.to_string() +
                            ", trying to connect to PLMN Id=" + known_plmns[0].to_string();
    logger.info("%s", debug_str.c_str());
    srsran::console("%s\n", debug_str.c_str());
    current_plmn = known_plmns[0];
    state.set_deregistered(emm_state_t::deregistered_substate_t::normal_service);
  }
  //......
}
```
nas::plmn_search_proc::react 会返回success, 类似于之前分析RRC的方式，返回success会触发该proc的then(上面RRC分析过类似的过程):
```C++
void nas::plmn_search_proc::then(const srsran::proc_state_t& result)
{
  ProcInfo("Completed with %s", result.is_success() ? "success" : "failure");

  if (result.is_error()) {
    nas_ptr->enter_emm_deregistered(emm_state_t::deregistered_substate_t::plmn_search);
  }
}
```
nas::plmn_search_proc::then 其实就是打印了LOG

## 总结
RRC最后会移除plmn_searcher，NAS设置了normal_service的状态。下一次NAS TTI的时候，就会发起attach请求。

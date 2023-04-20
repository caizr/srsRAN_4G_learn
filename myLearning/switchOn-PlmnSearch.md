# plmn搜索 代码总结
## 流程图

## 代码
### callback_list说明
在rrc::plmn_search中，可以看到launch之后，会将plmn_searcher放进callback_list中：
```c++
bool rrc::plmn_search()
{
  if (not plmn_searcher.launch()) {
    logger.error("Unable to initiate PLMN search");
    return false;
  }
  // plmn_searcher可以查看定义
  callback_list.add_proc(plmn_searcher);
  return true;
}
// add_proc:
void add_proc(proc_t<T, ResultType>&& proc)
{
  if (proc.is_idle()) {
    return;
  }
  proc_obj_t ptr(new proc_t<T, ResultType>(std::move(proc)), std::default_delete<proc_base_t>());
  proc_list.push_back(std::move(ptr));
}
```
每次rrc::run_tti都会运行callback_list中的函数:
```c++
void run()
{
  // Calls run for all callbacks. Remove the ones that have finished. The proc dtor is called.
  proc_list.remove_if([](proc_obj_t& elem) { return not elem->run(); });
}
```
remove_if会遍历列表中的每个元素，并且作为函数的参数，当函数返回结果返回为true时，从列表移除。proc_obj_t为proc_base_t指针，前面提到的plmn_searcher继承proc_t,
proc_t继承proc_base_t:
```c++
// plmn_searcher定义
srsran::proc_t<plmn_search_proc>    plmn_searcher;
// proc_t 部分成员介绍
proc_status_t proc_state = proc_status_t::idle;  // launch的时候置为on_going
bool run()                                       // elem->run()的地方
{
  if (is_busy()) {  // proc_state == on_going
    proc_outcome_t outcome = step();   // 运行模板的step函数
    handle_outcome(outcome);   // outcome为success时置为idle
  }
  return is_busy();
}
```
从代码中可以看出，直到proc_t<T>中的T->step()运行的结果为success时，handle_outcome会将proc_status_t置为idle, 从而出发remove_if删除T。
<font color="red">launch, handle_outcome的逻辑后续再说</font>


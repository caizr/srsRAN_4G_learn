# RRC meas_cells处理分析
首先介绍meas_cells的类型:
```c++
meas_cell_list<meas_cell_eutra> meas_cells;
/*  meas_cell_list 部分成员 */
// public:
const static int MAX_NEIGHBOUR_CELLS = 8;
bool add_meas_cell(const phy_meas_t& meas);
bool add_meas_cell(unique_meas_cell cell); 
void rem_last_neighbour();  // 删除neighbour_cells中的最后一个小区
unique_meas_cell remove_neighbour_cell(uint32_t earfcn, uint32_t pci);
void sort_neighbour_cells(); // 依据rsrp排序小区
T* get_neighbour_cell_handle(uint32_t earfcn, uint32_t pci);
int set_serving_cell(phy_cell_t phy_cell, bool discard_serving);
T& serving_cell() { return *serv_cell; }
// private
bool add_neighbour_cell_unsorted(unique_meas_cell cell);
unique_meas_cell serv_cell;
std::vector<unique_meas_cell> neighbour_cells;

```

## handle_cell_found 处理流程

handle_cell_found处理的时机参考cell_search的时序图，接下来分析该函数：
```c++
proc_outcome_t rrc::cell_search_proc::handle_cell_found(const phy_cell_t& new_cell)
{
  Info("Cell found in this frequency. Setting new serving cell EARFCN=%d PCI=%d ...", new_cell.earfcn, new_cell.pci);

  // Create a cell with NaN RSRP. Will be updated by new_phy_meas() during SIB search.
  if (not rrc_ptr->meas_cells.add_meas_cell(
          unique_cell_t(new meas_cell_eutra(new_cell, rrc_ptr->task_sched.get_unique_timer())))) {
    Error("Could not add new found cell");
    return proc_outcome_t::error;
  }

  rrc_ptr->meas_cells.set_serving_cell(new_cell, false);

  // set new serving cell in PHY
  state = state_t::phy_cell_select;
  if (not rrc_ptr->phy_ctrl->start_cell_select(rrc_ptr->meas_cells.serving_cell().phy_cell, rrc_ptr->cell_searcher)) {
    Error("Couldn't start phy cell selection");
    return proc_outcome_t::error;
  }
  return proc_outcome_t::yield;
}
```
首先添加测量小区, add_meas_cell一系列的动作如下: 
```c++
bool meas_cell_list<T>::add_meas_cell(unique_meas_cell cell)
{
  // 下面进行分析add_neighbour_cell_unsorted和sort_neighbour_cells
  bool ret = add_neighbour_cell_unsorted(std::move(cell));
  if (ret) {
    sort_neighbour_cells();
  }
  return ret;
}
/* add_neighbour_cell_unsorted */
bool meas_cell_list<T>::add_neighbour_cell_unsorted(unique_meas_cell new_cell)
{
  // 1. earfcn != 0 ; 2. pci < 504
  if (!new_cell->is_valid()) {
    logger.error("Trying to add cell %s but is not valid", new_cell->to_string().c_str());
    return false;
  }
  // 如果earfcn, pci与serv_cell一致, 不用重新添加
  if (is_same_cell(serving_cell(), *new_cell)) {
    logger.info("Added neighbour cell %s is serving cell", new_cell->to_string().c_str());
    serv_cell = std::move(new_cell);
    return true;
  }

  // 如果neighbour_cells中存在搜索到的小区, 也不用重新添加, 只需要更新rsrp, 该函数附录有解析
  T* existing_cell = get_neighbour_cell_handle(new_cell->get_earfcn(), new_cell->get_pci());
  if (existing_cell != nullptr) {
    if (std::isnormal(new_cell.get()->get_rsrp())) {
      existing_cell->set_rsrp(new_cell.get()->get_rsrp());
    }
    logger.info("Updated neighbour cell %s rsrp=%f", new_cell->to_string().c_str(), new_cell.get()->get_rsrp());
    return true;
  }
  // 邻小区列表填满时, 除非新小区rsrp大于列表中的最后一个小区, 否则不添加
  if (neighbour_cells.size() >= MAX_NEIGHBOUR_CELLS) {
    // If there isn't space, keep the strongest only
    if (not new_cell->greater(neighbour_cells.back().get())) {
      logger.warning("Could not add cell %s: no space in neighbours", new_cell->to_string().c_str());
      return false;
    }
    // 删除邻小区列表中的最后一个小区
    rem_last_neighbour();
  }

  logger.info(
      "Adding neighbour cell %s, nof_neighbours=%zd", new_cell->to_string().c_str(), neighbour_cells.size() + 1);
  neighbour_cells.push_back(std::move(new_cell));
  return true;
}
/* sort_neighbour_cells() */
void meas_cell_list<T>::sort_neighbour_cells()
{
  std::sort(std::begin(neighbour_cells),
            std::end(neighbour_cells),
            [](const unique_meas_cell& a, const unique_meas_cell& b) { return a->greater(b.get()); });

  log_neighbour_cells();
}
```
可以看到, 在serv_cell与搜索到的小区一致、邻小区列表中发现搜索到的小区、搜索到的小区成功添加到邻小区列表，这三种情况时，handle_cell_found会把
搜索到的小区设置到serv_cell中。最后serv_cell

## 附录
rsrp的更新: 目前看到rrc.cc new_cell_meas会更新rsrp, 在这里打点溯源。process_cell_meas会把测量的结果更新到meas_cell中。
### get_neighbour_cell_handle
```c++
T* meas_cell_list<T>::get_neighbour_cell_handle(uint32_t earfcn, uint32_t pci)
{
  // 查找列表中是否存在一致的小区, 代码写法学习一下
  auto it = find_if(neighbour_cells.begin(), neighbour_cells.end(), [&](const unique_meas_cell& cell) {
    return cell->equals(earfcn, pci);
  });
  return it != neighbour_cells.end() ? it->get() : nullptr;
}
```
### greater
### rem_last_neighbour
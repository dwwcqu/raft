/*
 * Copyright (c) 2018-2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <raft/core/device_mdspan.hpp>
#include <raft/core/device_resources.hpp>
#include <raft/core/error.hpp>
#include <raft/matrix/detail/batched_rearrange.cuh>

namespace raft {
namespace matrix {

/**
 * @brief In-place gather elements in a row-major matrix according to a
 * map. The length of the map is equal to the number of rows.
 * Batching is done on columns and an additional scratch space of
 * shape n_rows * cols_batch_size is created. For each batch, chunks
 * of columns from each row are copied into the appropriate location
 * in the scratch space and copied back to the corresponding locations
 * in the input matrix
 *
 * @tparam value_idx
 * @tparam value_t
 *
 * @param[in] handle raft handle
 * @param[inout] in input matrix (n_rows * n_cols)
 * @param[in] map map containing the order in which rows are to be rearranged (n_rows)
 * @param[in] col_batch_size column batch size
 */
template <typename T, typename IdxT>
void batched_gather(raft::device_resources const& handle,
                    raft::device_matrix_view<T, IdxT, raft::layout_c_contiguous> in,
                    raft::device_vector_view<IdxT, IdxT, raft::layout_c_contiguous> map,
                    size_t col_batch_size)
{
  IdxT m       = in.extent(0);
  IdxT n       = in.extent(1);
  IdxT map_len = map.extent(0);
  RAFT_EXPECTS(0 < col_batch_size && col_batch_size <= (size_t)n,
               "col_batch_size should be > 0 and <= n");
  RAFT_EXPECTS(map_len == m, "size of map should be equal to the number of rows in input matrix");

  detail::batched_gather(handle, in.data_handle(), map.data_handle(), n, m, col_batch_size);
}

/**
 * @brief In-place scatter elements in a row-major matrix according to a
 * map. The length of the map is equal to the number of rows.
 * Batching is done on columns and an additional scratch space of
 * shape n_rows * cols_batch_size is created. For each batch, chunks
 * of columns from each row are copied into the appropriate location
 * in the scratch space and copied back to the corresponding locations
 * in the input matrix
 *
 * @tparam value_idx
 * @tparam value_t
 *
 * @param[in] handle raft handle
 * @param[inout] in input matrix (n_rows * n_cols)
 * @param[in] map map containing destination index of each row (n_rows)
 * @param[in] col_batch_size column batch size
 */
template <typename T, typename IdxT>
void batched_scatter(raft::device_resources const& handle,
                     raft::device_matrix_view<T, IdxT, raft::layout_c_contiguous> in,
                     raft::device_vector_view<IdxT, IdxT, raft::layout_c_contiguous> map,
                     size_t col_batch_size)
{
  IdxT m       = in.extent(0);
  IdxT n       = in.extent(1);
  IdxT map_len = map.extent(0);
  RAFT_EXPECTS(0 < col_batch_size && col_batch_size <= (size_t)n,
               "col_batch_size should be > 0 and <= n");
  RAFT_EXPECTS(map_len == m, "size of map should be equal to the number of rows in input matrix");

  detail::batched_scatter(handle, in.data_handle(), map.data_handle(), n, m, col_batch_size);
}
};  // end namespace matrix
};  // end namespace raft
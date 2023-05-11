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

#include <raft/core/device_resources.hpp>
#include <raft/distance/distance_types.hpp>
#include <raft/sparse/coo.hpp>
#include <raft/sparse/neighbors/detail/connect_components.cuh>

namespace raft::sparse::neighbors {

template <typename value_idx, typename value_t>
using FixConnectivitiesRedOp = detail::FixConnectivitiesRedOp<value_idx, value_t>;

/**
 * Gets the number of unique components from array of
 * colors or labels. This does not assume the components are
 * drawn from a monotonically increasing set.
 * @tparam value_idx
 * @param[in] colors array of components
 * @param[in] n_rows size of components array
 * @param[in] stream cuda stream for which to order cuda operations
 * @return total number of components
 */
template <typename value_idx>
value_idx get_n_components(value_idx* colors, size_t n_rows, cudaStream_t stream)
{
  return detail::get_n_components(colors, n_rows, stream);
}

/**
 * Connects the components of an otherwise unconnected knn graph
 * by computing a 1-nn to neighboring components of each data point
 * (e.g. component(nn) != component(self)) and reducing the results to
 * include the set of smallest destination components for each source
 * component. The result will not necessarily contain
 * n_components^2 - n_components number of elements because many components
 * will likely not be contained in the neighborhoods of 1-nns.
 * @tparam value_idx
 * @tparam value_t
 * @param[in] handle raft handle
 * @param[out] out output edge list containing nearest cross-component
 *             edges.
 * @param[in] X original (row-major) dense matrix for which knn graph should be constructed.
 * @param[in] orig_colors array containing component number for each row of X
 * @param[in] n_rows number of rows in X
 * @param[in] n_cols number of cols in X
 * @param[in] reduction_op reduction operation for computing nearest neighbors. The reduction
 * operation must have `gather` and `scatter` functions defined. For single linkage clustering,
 * these functions are no-ops. For HDBSCAN, they sort and 'unsort' the core distances based on color
 * @param[in] row_batch_size the batch size for computing nearest neighbors. This parameter controls
 * the number of samples for which the nearest neighbors are computed at once. Therefore, it affects
 * the memory consumption mainly by reducing the size of the adjacency matrix for masked nearest
 * neighbors computation
 * @param[in] col_batch_size the input data is sorted and 'unsorted' based on color. An additional
 * scratch space buffer of shape (n_rows, col_batch_size) is created for this. Usually, this
 * parameter affects the memory consumption more drastically than the col_batch_size with a marginal
 * increase in compute time as the col_batch_size is reduced
 */
template <typename value_idx, typename value_t, typename red_op>
void connect_components(raft::device_resources const& handle,
                        raft::sparse::COO<value_t, value_idx>& out,
                        const value_t* X,
                        const value_idx* orig_colors,
                        size_t n_rows,
                        size_t n_cols,
                        red_op reduction_op,
                        size_t row_batch_size = 256,
                        size_t col_batch_size = 32)
{
  detail::connect_components(
    handle, out, X, orig_colors, n_rows, n_cols, reduction_op, row_batch_size, col_batch_size);
}

};  // end namespace raft::sparse::neighbors
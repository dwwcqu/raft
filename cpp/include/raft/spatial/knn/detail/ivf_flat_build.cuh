/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
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

#include "ann_utils.cuh"

#include <raft/cluster/kmeans_balanced.cuh>
#include <raft/core/device_resources.hpp>
#include <raft/core/logger.hpp>
#include <raft/core/mdarray.hpp>
#include <raft/core/nvtx.hpp>
#include <raft/core/operators.hpp>
#include <raft/core/serialize.hpp>
#include <raft/linalg/add.cuh>
#include <raft/linalg/map.cuh>
#include <raft/linalg/norm.cuh>
#include <raft/neighbors/ivf_flat_types.hpp>
#include <raft/stats/histogram.cuh>
#include <raft/util/pow2_utils.cuh>

#include <rmm/cuda_stream_view.hpp>

#include <cstdint>
#include <fstream>

namespace raft::spatial::knn::ivf_flat::detail {

using namespace raft::spatial::knn::detail;  // NOLINT
using namespace raft::neighbors::ivf_flat;   // NOLINT

using raft::neighbors::ivf_flat::index;
using raft::neighbors::ivf_flat::index_params;
using raft::neighbors::ivf_flat::kIndexGroupSize;
using raft::neighbors::ivf_flat::search_params;
using raft::neighbors::ivf_flat::list_data;
/**
  * Resize a list by the given id, so that it can contain the given number of records;
  * possibly, copy the data.
  *
  * Besides resizing the corresponding list_data, this function updates the device pointers
  *   data_ptrs, inds_ptrs, and the list_sizes if necessary.
  *
  * The new `list_sizes(label)` represents the number of valid records in the index;
  * it can be `list_size` if the previous size was not smaller; otherwise it's not updated.
  *
  * @param[in] handle
  * @param[in] label list id
  * @param[in] list_size the minimum size the list should grow.
  */
template <typename T, typename IdxT, typename SizeT = uint32_t>
void resize_list(raft::device_resources const& handle, 
                 std::shared_ptr<list_data<T, IdxT, SizeT>>& orig_list,
                 SizeT new_used_size,
                 SizeT old_used_size,
                 uint32_t dim)
{
  bool skip_resize = false;
  // TODO update total_size
  if (orig_list) {
    if (new_used_size <= orig_list->indices.extent(0)) {
      auto shared_list_size = old_used_size;
      if (new_used_size <= old_used_size ||
          orig_list->size.compare_exchange_strong(shared_list_size, new_used_size)) {
        // We don't need to resize the list if:
        //  1. The list exists
        //  2. The new size fits in the list
        //  3. The list doesn't grow or no-one else has grown it yet
        skip_resize = true;
      }
    }
  } else {
    old_used_size = 0;
  }
  if (skip_resize) { return; }
  auto new_list = std::make_shared<list_data<T, IdxT>>(handle, new_used_size, dim);
  if (old_used_size > 0) {
    auto copied_data_extents = make_extents<SizeT>(old_used_size, dim);
    auto copied_view         = make_mdspan<T, SizeT, row_major, false, true>(
      new_list->data.data_handle(), copied_data_extents);
    copy(copied_view.data_handle(),
         orig_list->data.data_handle(),
         copied_view.size(),
         handle.get_stream());
    copy(new_list->indices.data_handle(),
         orig_list->indices.data_handle(),
         old_used_size,
         handle.get_stream());
  }
  // swap the shared pointer content with the new list
  new_list.swap(orig_list);
}

/**
 * @brief Record the dataset into the index, one source row at a time.
 *
 * The index consists of the dataset rows, grouped by their labels (into clusters/lists).
 * Within each cluster (list), the data is grouped into blocks of `WarpSize` interleaved
 * vectors. Note, the total index length is slightly larger than the dataset length, because
 * each cluster is padded by `WarpSize` elements
 *
 * CUDA launch grid:
 *   X dimension must cover the dataset (n_rows), YZ are not used;
 *   there are no dependencies between threads, hence no constraints on the block size.
 *
 * @tparam T      element type.
 * @tparam IdxT   type of the indices in the source source_vecs
 * @tparam LabelT label type
 * @tparam gather_src if false, then we build the index from vectors source_vecs[i,:], otherwise
 *     we use source_vecs[source_ixs[i],:]. In both cases i=0..n_rows-1.
 *
 * @param[in] labels device pointer to the cluster ids for each row [n_rows]
 * @param[in] list_offsets device pointer to the cluster offsets in the output (index) [n_lists]
 * @param[in] source_vecs device pointer to the input data [n_rows, dim]
 * @param[in] source_ixs device pointer to the input indices [n_rows]
 * @param[out] list_data device pointer to the output [index_size, dim]
 * @param[out] list_index device pointer to the source ids corr. to the output [index_size]
 * @param[out] list_sizes_ptr device pointer to the cluster sizes [n_lists];
 *                          it's used as an atomic counter, and must be initialized with zeros.
 * @param n_rows source length
 * @param dim the dimensionality of the data
 * @param veclen size of vectorized loads/stores; must satisfy `dim % veclen == 0`.
 *
 */
template <typename T, typename IdxT, typename LabelT, bool gather_src = false>
__global__ void build_index_kernel(const LabelT* labels,
                                   //const IdxT* list_offsets,
                                   const T* source_vecs,
                                   const IdxT* source_ixs,
                                   T** list_data_ptrs,
                                   IdxT** list_index_ptrs,
                                   uint32_t* list_sizes_ptr,
                                   IdxT n_rows,
                                   uint32_t dim,
                                   uint32_t veclen)
{
  const IdxT i = IdxT(blockDim.x) * IdxT(blockIdx.x) + threadIdx.x;
  if (i >= n_rows) { return; }

  auto list_id     = labels[i];
  auto inlist_id   = atomicAdd(list_sizes_ptr + list_id, 1);
  auto* list_index = list_index_ptrs[list_id];
  auto* list_data  = list_data_ptrs[list_id];

  // Record the source vector id in the index
  list_index[inlist_id] = source_ixs == nullptr ? i : source_ixs[i];

  // The data is written in interleaved groups of `index::kGroupSize` vectors
  using interleaved_group = Pow2<kIndexGroupSize>;
  auto group_offset       = interleaved_group::roundDown(inlist_id);
  auto ingroup_id         = interleaved_group::mod(inlist_id) * veclen;

  // Point to the location of the interleaved group of vectors
  list_data += group_offset * dim;

  // Point to the source vector
  if constexpr (gather_src) {
    source_vecs += source_ixs[i] * dim;
  } else {
    source_vecs += i * dim;
  }
  // Interleave dimensions of the source vector while recording it.
  // NB: such `veclen` is selected, that `dim % veclen == 0`
  for (uint32_t l = 0; l < dim; l += veclen) {
    for (uint32_t j = 0; j < veclen; j++) {
      list_data[l * kIndexGroupSize + ingroup_id + j] = source_vecs[l + j];
    }
  }
}

/** See raft::spatial::knn::ivf_flat::extend docs */
template <typename T, typename IdxT>
void extend(raft::device_resources const& handle,
            index<T, IdxT>* index,
            const T* new_vectors,
            const IdxT* new_indices,
            IdxT n_rows)
{
  using LabelT = uint32_t;
  RAFT_EXPECTS(index != nullptr, "index cannot be empty.");

  auto stream  = handle.get_stream();
  auto n_lists = index->n_lists();
  auto dim     = index->dim();
  common::nvtx::range<common::nvtx::domain::raft> fun_scope(
    "ivf_flat::extend(%zu, %u)", size_t(n_rows), dim);

  RAFT_EXPECTS(new_indices != nullptr || index->size() == 0,
               "You must pass data indices when the index is non-empty.");

  auto new_labels = raft::make_device_vector<LabelT, IdxT>(handle, n_rows);
  raft::cluster::kmeans_balanced_params kmeans_params;
  kmeans_params.metric     = index->metric();
  auto new_vectors_view    = raft::make_device_matrix_view<const T, IdxT>(new_vectors, n_rows, dim);
  auto orig_centroids_view = raft::make_device_matrix_view<const float, IdxT>(
    index->centers().data_handle(), n_lists, dim);
  raft::cluster::kmeans_balanced::predict(handle,
                                          kmeans_params,
                                          new_vectors_view,
                                          orig_centroids_view,
                                          new_labels.view(),
                                          utils::mapping<float>{});

  auto* list_sizes_ptr   = index->list_sizes().data_handle();
  auto old_list_sizes_dev =  raft::make_device_vector<uint32_t, IdxT>(handle, n_lists);
  copy(old_list_sizes_dev.data_handle(), list_sizes_ptr, n_lists, stream);

  // Calculate the centers and sizes on the new data, starting from the original values
  if (index->adaptive_centers()) {
    auto centroids_view = raft::make_device_matrix_view<float, IdxT>(index->centers().data_handle(), index->centers().extent(0), index->centers().extent(1));
    auto list_sizes_view =
      raft::make_device_vector_view<std::remove_pointer_t<decltype(list_sizes_ptr)>, IdxT>(
        list_sizes_ptr, n_lists);
    auto const_labels_view = make_const_mdspan(new_labels.view());
    raft::cluster::kmeans_balanced::helpers::calc_centers_and_sizes(handle,
                                                                    new_vectors_view,
                                                                    const_labels_view,
                                                                    centroids_view,
                                                                    list_sizes_view,
                                                                    false,
                                                                    utils::mapping<float>{});
  } else {
    raft::stats::histogram<uint32_t, IdxT>(raft::stats::HistTypeAuto,
                                           reinterpret_cast<int32_t*>(list_sizes_ptr),
                                           IdxT(n_lists),
                                           new_labels.data_handle(),
                                           n_rows,
                                           1,
                                           stream);
    raft::linalg::add(
      list_sizes_ptr, list_sizes_ptr, old_list_sizes_dev.data_handle(), n_lists, stream);
  }

  // Calculate and allocate new list data
  {
    std::vector<uint32_t> new_list_sizes(n_lists);
    std::vector<uint32_t> old_list_sizes(n_lists);
    copy(old_list_sizes.data(), old_list_sizes_dev.data_handle(), n_lists, stream);
    copy(new_list_sizes.data(), list_sizes_ptr, n_lists, stream);
    handle.sync_stream();
    auto lists = index->lists();
    for (uint32_t label = 0; label < n_lists; label++) {
      resize_list(handle,
                  lists(label),
                  new_list_sizes[label],
                  old_list_sizes[label],
                  index->dim());
      }
  }
  // Update the pointers and the sizes
  index->recompute_internal_state(handle);

  // Copy the old sizes, so we can start from the current state of the index;
  // we'll rebuild the `list_sizes_ptr` in the following kernel, using it as an atomic counter.
  raft::copy(
    list_sizes_ptr, old_list_sizes_dev.data_handle(), n_lists, stream);

  // Kernel to insert the new vectors
  const dim3 block_dim(256);
  const dim3 grid_dim(raft::ceildiv<IdxT>(n_rows, block_dim.x));
  build_index_kernel<<<grid_dim, block_dim, 0, stream>>>(new_labels.data_handle(),
                                                         new_vectors,
                                                         new_indices,
                                                         index->data_ptrs().data_handle(),
                                                         index->inds_ptrs().data_handle(),
                                                         list_sizes_ptr,
                                                         n_rows,
                                                         dim,
                                                         index->veclen());
  RAFT_CUDA_TRY(cudaPeekAtLastError());

  // Precompute the centers vector norms for L2Expanded distance
  if (index->center_norms().has_value() && index->adaptive_centers()) {
    raft::linalg::rowNorm(index->center_norms()->data_handle(),
                          index->centers().data_handle(),
                          dim,
                          n_lists,
                          raft::linalg::L2Norm,
                          true,
                          stream);
    RAFT_LOG_TRACE_VEC(index->center_norms()->data_handle(), std::min<uint32_t>(dim, 20));
  }
}

/** See raft::spatial::knn::ivf_flat::extend docs */
template <typename T, typename IdxT>
auto extend(raft::device_resources const& handle,
            const index<T, IdxT>& orig_index,
            const T* new_vectors,
            const IdxT* new_indices,
            IdxT n_rows) -> index<T, IdxT>
{
  auto ext_index = clone(handle, &orig_index);
  extend(handle, &ext_index, new_vectors, new_indices, n_rows);
  return ext_index;
}


/** See raft::spatial::knn::ivf_flat::build docs */
template <typename T, typename IdxT>
inline auto build(raft::device_resources const& handle,
                  const index_params& params,
                  const T* dataset,
                  IdxT n_rows,
                  uint32_t dim) -> index<T, IdxT>
{
  auto stream = handle.get_stream();
  common::nvtx::range<common::nvtx::domain::raft> fun_scope(
    "ivf_flat::build(%zu, %u)", size_t(n_rows), dim);
  static_assert(std::is_same_v<T, float> || std::is_same_v<T, uint8_t> || std::is_same_v<T, int8_t>,
                "unsupported data type");
  RAFT_EXPECTS(n_rows > 0 && dim > 0, "empty dataset");

  index<T, IdxT> index(handle, params, dim);
  utils::memzero(index.list_sizes().data_handle(), index.list_sizes().size(), stream);
  utils::memzero(index.data_ptrs().data_handle(), index.data_ptrs().size(), stream);
  utils::memzero(index.inds_ptrs().data_handle(), index.inds_ptrs().size(), stream);

  // Train the kmeans clustering
  {
    auto trainset_ratio = std::max<size_t>(
      1, n_rows / std::max<size_t>(params.kmeans_trainset_fraction * n_rows, index.n_lists()));
    auto n_rows_train = n_rows / trainset_ratio;
    rmm::device_uvector<T> trainset(n_rows_train * index.dim(), stream);
    // TODO: a proper sampling
    RAFT_CUDA_TRY(cudaMemcpy2DAsync(trainset.data(),
                                    sizeof(T) * index.dim(),
                                    dataset,
                                    sizeof(T) * index.dim() * trainset_ratio,
                                    sizeof(T) * index.dim(),
                                    n_rows_train,
                                    cudaMemcpyDefault,
                                    stream));
    auto trainset_const_view =
      raft::make_device_matrix_view<const T, IdxT>(trainset.data(), n_rows_train, index.dim());
    auto centers_view = raft::make_device_matrix_view<float, IdxT>(
      index.centers().data_handle(), index.n_lists(), index.dim());
    raft::cluster::kmeans_balanced_params kmeans_params;
    kmeans_params.n_iters = params.kmeans_n_iters;
    kmeans_params.metric  = index.metric();
    raft::cluster::kmeans_balanced::fit(
      handle, kmeans_params, trainset_const_view, centers_view, utils::mapping<float>{});
  }

  // add the data if necessary
  if (params.add_data_on_build) {
    detail::extend<T, IdxT>(handle, &index, dataset, nullptr, n_rows);
  }
  return index;
}

/**
 * Build an index that can be used in refinement operation.
 *
 * See raft::neighbors::refine for details on the refinement operation.
 *
 * The returned index cannot be used for a regular ivf_flat::search. The index misses information
 * about coarse clusters. Instead, the neighbor candidates are assumed to form clusters, one for
 * each query. The candidate vectors are gathered into the index dataset, that can be later used
 * in ivfflat_interleaved_scan.
 *
 * @param[in] handle the raft handle
 * @param[inout] refinement_index
 * @param[in] dataset device pointer to dataset vectors, size [n_rows, dim]. Note that n_rows is
 *   not known to this function, but each candidate_idx has to be smaller than n_rows.
 * @param[in] candidate_idx device pointer to neighbor candidates, size [n_queries, n_candidates]
 * @param[in] n_candidates  of neighbor_candidates
 */
template <typename T, typename IdxT>
inline void fill_refinement_index(raft::device_resources const& handle,
                                  index<T, IdxT>* refinement_index,
                                  const T* dataset,
                                  const IdxT* candidate_idx,
                                  IdxT n_queries,
                                  uint32_t n_candidates)
{
  using LabelT = uint32_t;

  auto stream      = handle.get_stream();
  uint32_t n_lists = n_queries;
  common::nvtx::range<common::nvtx::domain::raft> fun_scope(
    "ivf_flat::fill_refinement_index(%zu, %u)", size_t(n_queries));

  rmm::device_uvector<LabelT> new_labels(n_queries * n_candidates, stream);
  auto new_labels_view =
    raft::make_device_vector_view<LabelT, IdxT>(new_labels.data(), n_queries * n_candidates);
  linalg::map_offset(
    handle,
    new_labels_view,
    raft::compose_op(raft::cast_op<LabelT>(), raft::div_const_op<IdxT>(n_candidates)));

  auto list_sizes_ptr   = refinement_index->list_sizes().data_handle();
  // We do not fill centers and center norms, since we will not run coarse search.

  // Allocate new memory
  auto lists = refinement_index->lists();
  for (uint32_t label = 0; label < n_lists; label++) {
    resize_list(handle,
                lists(label),
                n_candidates,
                uint32_t(0),
                refinement_index->dim());
  }

  RAFT_CUDA_TRY(cudaMemsetAsync(list_sizes_ptr, 0, n_lists * sizeof(uint32_t), stream));

  const dim3 block_dim(256);
  const dim3 grid_dim(raft::ceildiv<IdxT>(n_queries * n_candidates, block_dim.x));
  build_index_kernel<T, IdxT, LabelT, true>
    <<<grid_dim, block_dim, 0, stream>>>(new_labels.data(),
                                         dataset,
                                         candidate_idx,
                                         refinement_index->data_ptrs().data_handle(),
                                         refinement_index->inds_ptrs().data_handle(),
                                         list_sizes_ptr,
                                         n_queries * n_candidates,
                                         refinement_index->dim(),
                                         refinement_index->veclen());
  RAFT_CUDA_TRY(cudaPeekAtLastError());
}

// Serialization version 3
// No backward compatibility yet; that is, can't add additional fields without breaking
// backward compatibility.
// TODO(hcho3) Implement next-gen serializer for IVF that allows for expansion in a backward
//             compatible fashion.
constexpr int serialization_version = 3;

// NB: we wrap this check in a struct, so that the updated RealSize is easy to see in the error
// message.
template <size_t RealSize, size_t ExpectedSize>
struct check_index_layout {
  static_assert(RealSize == ExpectedSize,
                "The size of the index struct has changed since the last update; "
                "paste in the new size and consider updating the serialization logic");
};

template struct check_index_layout<sizeof(index<double, std::uint64_t>), 376>;


template <typename T, typename IdxT, typename SizeT>
void serialize_list(const raft::device_resources& handle,
                    std::ostream& os,
                    const list_data<T, IdxT, SizeT>& ld,
                    std::optional<SizeT> size_override = std::nullopt)
{
  auto size = size_override.value_or(ld.size.load());
  serialize_scalar(handle, os, size);
  if (size == 0) { return; }

  auto data_extents = make_extents<SizeT>(size, ld.data.extent(1));
  auto data_array   = make_host_mdarray<T, SizeT, row_major>(data_extents);
  auto inds_array   = make_host_mdarray<IdxT, SizeT, row_major>(make_extents<SizeT>(size));
  copy(data_array.data_handle(), ld.data.data_handle(), data_array.size(), handle.get_stream());
  copy(inds_array.data_handle(), ld.indices.data_handle(), inds_array.size(), handle.get_stream());
  handle.sync_stream();
  serialize_mdspan(handle, os, data_array.view());
  serialize_mdspan(handle, os, inds_array.view());
}

template <typename T, typename IdxT, typename SizeT>
void serialize_list(const raft::device_resources& handle,
                    std::ostream& os,
                    const std::shared_ptr<const list_data<T, IdxT, SizeT>>& ld,
                    std::optional<SizeT> size_override = std::nullopt)
{
  if (ld) {
    return serialize_list(handle, os, *ld, size_override);
  } else {
    return serialize_scalar(handle, os, SizeT{0});
  }
}

template <typename T, typename IdxT, typename SizeT>
void deserialize_list(const raft::device_resources& handle,
                      std::istream& is,
                      std::shared_ptr<list_data<T, IdxT, SizeT>>& ld,
                      uint32_t dim)
{
  auto size = deserialize_scalar<SizeT>(handle, is);
  if (size == 0) { return ld.reset(); }
  std::make_shared<list_data<IdxT, SizeT>>(handle, size, dim).swap(ld);
  auto data_extents = make_extents<SizeT>(size, ld->data.extent(1));
  auto data_array   = make_host_mdarray<T, SizeT, row_major>(data_extents);
  auto inds_array   = make_host_mdarray<IdxT, SizeT, row_major>(make_extents<SizeT>(size));
  deserialize_mdspan(handle, is, data_array.view());
  deserialize_mdspan(handle, is, inds_array.view());
  copy(ld->data.data_handle(), data_array.data_handle(), data_array.size(), handle.get_stream());
  // NB: copying exactly 'size' indices to leave the rest 'kInvalidRecord' intact.
  copy(ld->indices.data_handle(), inds_array.data_handle(), size, handle.get_stream());
}

/**
 * Save the index to file.
 *
 * Experimental, both the API and the serialization format are subject to change.
 *
 * @param[in] handle the raft handle
 * @param[in] filename the file name for saving the index
 * @param[in] index_ IVF-Flat index
 *
 */
template <typename T, typename IdxT>
void serialize(raft::device_resources const& handle,
               const std::string& filename,
               const index<T, IdxT>& index_)
{
  std::ofstream of(filename, std::ios::out | std::ios::binary);
  if (!of) { RAFT_FAIL("Cannot open %s", filename.c_str()); }

  RAFT_LOG_DEBUG(
    "Saving IVF-Flat index, size %zu, dim %u", static_cast<size_t>(index_.size()), index_.dim());

  serialize_scalar(handle, of, serialization_version);
  serialize_scalar(handle, of, index_.size());
  serialize_scalar(handle, of, index_.dim());
  serialize_scalar(handle, of, index_.n_lists());
  serialize_scalar(handle, of, index_.metric());
  serialize_scalar(handle, of, index_.veclen());
  serialize_scalar(handle, of, index_.adaptive_centers());
  serialize_mdspan(handle, of, index_.list_sizes());
  serialize_mdspan(handle, of, index_.centers());
  if (index_.center_norms()) {
    bool has_norms = true;
    serialize_scalar(handle, of, has_norms);
    serialize_mdspan(handle, of, *index_.center_norms());
  } else {
    bool has_norms = false;
    serialize_scalar(handle, of, has_norms);
  }
  auto sizes_host = make_host_vector<uint32_t, uint32_t>(index_.list_sizes().extent(0));
  copy(sizes_host.data_handle(),
       index_.list_sizes().data_handle(),
       sizes_host.size(),
       handle.get_stream());
  handle.sync_stream();
  serialize_mdspan(handle, of, sizes_host.view());
  for (uint32_t label = 0; label < index_.n_lists(); label++) {
    serialize_list<T, IdxT, uint32_t>(handle, of, index_.lists()(label), sizes_host(label));
  }
  of.close();
  if (!of) { RAFT_FAIL("Error writing output %s", filename.c_str()); }
}

/** Load an index from file.
 *
 * Experimental, both the API and the serialization format are subject to change.
 *
 * @param[in] handle the raft handle
 * @param[in] filename the name of the file that stores the index
 * @param[in] index_ IVF-Flat index
 *
 */
template <typename T, typename IdxT>
auto deserialize(raft::device_resources const& handle, const std::string& filename)
  -> index<T, IdxT>
{
  std::ifstream infile(filename, std::ios::in | std::ios::binary);

  if (!infile) { RAFT_FAIL("Cannot open %s", filename.c_str()); }

  auto ver = deserialize_scalar<int>(handle, infile);
  if (ver != serialization_version) {
    RAFT_FAIL("serialization version mismatch, expected %d, got %d ", serialization_version, ver);
  }
  auto n_rows           = deserialize_scalar<IdxT>(handle, infile);
  auto dim              = deserialize_scalar<std::uint32_t>(handle, infile);
  auto n_lists          = deserialize_scalar<std::uint32_t>(handle, infile);
  auto metric           = deserialize_scalar<raft::distance::DistanceType>(handle, infile);
  auto veclen           = deserialize_scalar<std::uint32_t>(handle, infile);
  bool adaptive_centers = deserialize_scalar<bool>(handle, infile);

  index<T, IdxT> index_ =
    index<T, IdxT>(handle, metric, n_lists, adaptive_centers, dim);
  /* TODO
  index_.allocate(handle, n_rows);
  auto data = index_.data();
  deserialize_mdspan(handle, infile, data);
  deserialize_mdspan(handle, infile, index_.indices());
  deserialize_mdspan(handle, infile, index_.list_sizes());
  deserialize_mdspan(handle, infile, index_.list_offsets());
  deserialize_mdspan(handle, infile, index_.centers());
  bool has_norms = deserialize_scalar<bool>(handle, infile);
  if (has_norms) {
    if (!index_.center_norms()) {
      RAFT_FAIL("Error inconsistent center norms");
    } else {
      auto center_norms = *index_.center_norms();
      deserialize_mdspan(handle, infile, center_norms);
    }
  }
  index_.recompute_internal_state(handle);
  */
  infile.close();
  return index_;
}
}  // namespace raft::spatial::knn::ivf_flat::detail

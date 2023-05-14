/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
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

#include <raft/spatial/knn/detail/ann_utils.cuh>

#include <algorithm>
#include <cassert>
#include <iostream>
#include <memory>
#include <numeric>
#include <raft/core/device_mdspan.hpp>
#include <raft/core/device_resources.hpp>

#include <vector>

#include "bitonic.hpp"
#include "compute_distance.hpp"
#include "device_common.hpp"
#include "hashmap.hpp"
#include "search_multi_cta_kernel-inl.cuh"
#include "search_plan.cuh"
#include "topk_for_cagra/topk_core.cuh"  // TODO replace with raft topk if possible
#include "utils.hpp"
#include <raft/core/logger.hpp>
#include <raft/util/cuda_rt_essentials.hpp>
#include <raft/util/cudart_utils.hpp>  // RAFT_CUDA_TRY_NOT_THROW is used TODO(tfeher): consider moving this to cuda_rt_essentials.hpp

namespace raft::neighbors::experimental::cagra::detail {
namespace multi_cta_search {

#define SET_MC_KERNEL_3(BLOCK_SIZE, BLOCK_COUNT, MAX_ELEMENTS, LOAD_T) \
  kernel = search_kernel<TEAM_SIZE,                                    \
                         BLOCK_SIZE,                                   \
                         BLOCK_COUNT,                                  \
                         MAX_ELEMENTS,                                 \
                         MAX_DATASET_DIM,                              \
                         DATA_T,                                       \
                         DISTANCE_T,                                   \
                         INDEX_T,                                      \
                         LOAD_T>;

#define SET_MC_KERNEL_2(BLOCK_SIZE, BLOCK_COUNT, MAX_ELEMENTS)                    \
  if (load_bit_length == 128) {                                                   \
    SET_MC_KERNEL_3(BLOCK_SIZE, BLOCK_COUNT, MAX_ELEMENTS, device::LOAD_128BIT_T) \
  } else if (load_bit_length == 64) {                                             \
    SET_MC_KERNEL_3(BLOCK_SIZE, BLOCK_COUNT, MAX_ELEMENTS, device::LOAD_64BIT_T)  \
  }

#define SET_MC_KERNEL_1(MAX_ELEMENTS)         \
  /* if ( block_size == 32 ) {                \
      SET_MC_KERNEL_2( 32, 32, MAX_ELEMENTS ) \
  } else */                                   \
  if (block_size == 64) {                     \
    SET_MC_KERNEL_2(64, 16, MAX_ELEMENTS)     \
  } else if (block_size == 128) {             \
    SET_MC_KERNEL_2(128, 8, MAX_ELEMENTS)     \
  } else if (block_size == 256) {             \
    SET_MC_KERNEL_2(256, 4, MAX_ELEMENTS)     \
  } else if (block_size == 512) {             \
    SET_MC_KERNEL_2(512, 2, MAX_ELEMENTS)     \
  } else {                                    \
    SET_MC_KERNEL_2(1024, 1, MAX_ELEMENTS)    \
  }

#define SET_MC_KERNEL                                                       \
  typedef void (*search_kernel_t)(INDEX_T* const result_indices_ptr,        \
                                  DISTANCE_T* const result_distances_ptr,   \
                                  const DATA_T* const dataset_ptr,          \
                                  const size_t dataset_dim,                 \
                                  const size_t dataset_size,                \
                                  const DATA_T* const queries_ptr,          \
                                  const INDEX_T* const knn_graph,           \
                                  const uint32_t graph_degree,              \
                                  const unsigned num_distilation,           \
                                  const uint64_t rand_xor_mask,             \
                                  const INDEX_T* seed_ptr,                  \
                                  const uint32_t num_seeds,                 \
                                  uint32_t* const visited_hashmap_ptr,      \
                                  const uint32_t hash_bitlen,               \
                                  const uint32_t itopk_size,                \
                                  const uint32_t num_parents,               \
                                  const uint32_t min_iteration,             \
                                  const uint32_t max_iteration,             \
                                  uint32_t* const num_executed_iterations); \
  search_kernel_t kernel;                                                   \
  if (result_buffer_size <= 64) {                                           \
    SET_MC_KERNEL_1(64)                                                     \
  } else if (result_buffer_size <= 128) {                                   \
    SET_MC_KERNEL_1(128)                                                    \
  } else if (result_buffer_size <= 256) {                                   \
    SET_MC_KERNEL_1(256)                                                    \
  }

template <class T>
__global__ void set_value_batch_kernel(T* const dev_ptr,
                                       const std::size_t ld,
                                       const T val,
                                       const std::size_t count,
                                       const std::size_t batch_size)
{
  const auto tid = threadIdx.x + blockIdx.x * blockDim.x;
  if (tid >= count * batch_size) { return; }
  const auto batch_id              = tid / count;
  const auto elem_id               = tid % count;
  dev_ptr[elem_id + ld * batch_id] = val;
}

template <class T>
void set_value_batch(T* const dev_ptr,
                     const std::size_t ld,
                     const T val,
                     const std::size_t count,
                     const std::size_t batch_size,
                     cudaStream_t cuda_stream)
{
  constexpr std::uint32_t block_size = 256;
  const auto grid_size               = (count * batch_size + block_size - 1) / block_size;
  set_value_batch_kernel<T>
    <<<grid_size, block_size, 0, cuda_stream>>>(dev_ptr, ld, val, count, batch_size);
}

template <unsigned TEAM_SIZE,
          unsigned MAX_DATASET_DIM,
          typename DATA_T,
          typename INDEX_T,
          typename DISTANCE_T>

struct search : public search_plan_impl<DATA_T, INDEX_T, DISTANCE_T> {
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::max_queries;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::itopk_size;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::algo;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::team_size;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::num_parents;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::min_iterations;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::max_iterations;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::load_bit_length;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::thread_block_size;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::hashmap_mode;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::hashmap_min_bitlen;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::hashmap_max_fill_rate;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::num_random_samplings;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::rand_xor_mask;

  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::max_dim;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::dim;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::graph_degree;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::topk;

  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::hash_bitlen;

  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::small_hash_bitlen;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::small_hash_reset_interval;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::hashmap_size;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::dataset_size;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::result_buffer_size;

  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::smem_size;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::load_bit_lenght;

  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::hashmap;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::num_executed_iterations;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::dev_seed;
  using search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>::num_seeds;

  uint32_t num_cta_per_query;
  rmm::device_uvector<uint32_t> intermediate_indices;
  rmm::device_uvector<float> intermediate_distances;
  size_t topk_workspace_size;
  rmm::device_uvector<uint32_t> topk_workspace;

  search(raft::device_resources const& res,
         search_params params,
         int64_t dim,
         int64_t graph_degree,
         uint32_t topk)
    : search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>(res, params, dim, graph_degree, topk),
      intermediate_indices(0, res.get_stream()),
      intermediate_distances(0, res.get_stream()),
      topk_workspace(0, res.get_stream())

  {
    set_params(res);
  }

  void set_params(raft::device_resources const& res)
  {
    this->itopk_size   = 32;
    num_parents        = 1;
    num_cta_per_query  = max(num_parents, itopk_size / 32);
    result_buffer_size = itopk_size + num_parents * graph_degree;
    typedef raft::Pow2<32> AlignBytes;
    unsigned result_buffer_size_32 = AlignBytes::roundUp(result_buffer_size);
    // constexpr unsigned max_result_buffer_size = 256;
    RAFT_EXPECTS(result_buffer_size_32 <= 256, "Result buffer size cannot exceed 256");

    smem_size = sizeof(float) * max_dim +
                (sizeof(INDEX_T) + sizeof(DISTANCE_T)) * result_buffer_size_32 +
                sizeof(uint32_t) * num_parents + sizeof(uint32_t);
    RAFT_LOG_DEBUG("# smem_size: %u", smem_size);

    //
    // Determine the thread block size
    //
    constexpr unsigned min_block_size = 64;
    constexpr unsigned max_block_size = 1024;
    uint32_t block_size               = thread_block_size;
    if (block_size == 0) {
      block_size = min_block_size;

      // Increase block size according to shared memory requirements.
      // If block size is 32, upper limit of shared memory size per
      // thread block is set to 4096. This is GPU generation dependent.
      constexpr unsigned ulimit_smem_size_cta32 = 4096;
      while (smem_size > ulimit_smem_size_cta32 / 32 * block_size) {
        block_size *= 2;
      }

      // Increase block size to improve GPU occupancy when total number of
      // CTAs (= num_cta_per_query * max_queries) is small.
      cudaDeviceProp deviceProp = res.get_device_properties();
      RAFT_LOG_DEBUG("# multiProcessorCount: %d", deviceProp.multiProcessorCount);
      while ((block_size < max_block_size) &&
             (graph_degree * num_parents * team_size >= block_size * 2) &&
             (num_cta_per_query * max_queries <=
              (1024 / (block_size * 2)) * deviceProp.multiProcessorCount)) {
        block_size *= 2;
      }
    }
    RAFT_LOG_DEBUG("# thread_block_size: %u", block_size);
    RAFT_EXPECTS(block_size >= min_block_size,
                 "block_size cannot be smaller than min_block size, %u",
                 min_block_size);
    RAFT_EXPECTS(block_size <= max_block_size,
                 "block_size cannot be larger than max_block size %u",
                 max_block_size);
    thread_block_size = block_size;

    //
    // Determine load bit length
    //
    const uint32_t total_bit_length = dim * sizeof(DATA_T) * 8;
    if (load_bit_length == 0) {
      load_bit_length = 128;
      while (total_bit_length % load_bit_length) {
        load_bit_length /= 2;
      }
    }
    RAFT_LOG_DEBUG("# load_bit_length: %u  (%u loads per vector)",
                   load_bit_length,
                   total_bit_length / load_bit_length);
    RAFT_EXPECTS(total_bit_length % load_bit_length == 0,
                 "load_bit_length must be a divisor of dim*sizeof(data_t)*8=%u",
                 total_bit_length);
    RAFT_EXPECTS(load_bit_length >= 64, "load_bit_lenght cannot be less than 64");

    //
    // Allocate memory for intermediate buffer and workspace.
    //
    uint32_t num_intermediate_results = num_cta_per_query * itopk_size;
    intermediate_indices.resize(num_intermediate_results, res.get_stream());
    intermediate_distances.resize(num_intermediate_results, res.get_stream());

    hashmap.resize(hashmap_size, res.get_stream());

    topk_workspace_size = _cuann_find_topk_bufferSize(
      topk, max_queries, num_intermediate_results, utils::get_cuda_data_type<DATA_T>());
    RAFT_LOG_DEBUG("# topk_workspace_size: %lu", topk_workspace_size);
    topk_workspace.resize(topk_workspace_size, res.get_stream());
  }

  ~search() {}

  void operator()(raft::device_resources const& res,
                  raft::device_matrix_view<const DATA_T, INDEX_T, row_major> dataset,
                  raft::device_matrix_view<const INDEX_T, INDEX_T, row_major> graph,
                  INDEX_T* const topk_indices_ptr,          // [num_queries, topk]
                  DISTANCE_T* const topk_distances_ptr,     // [num_queries, topk]
                  const DATA_T* const queries_ptr,          // [num_queries, dataset_dim]
                  const uint32_t num_queries,
                  const INDEX_T* dev_seed_ptr,              // [num_queries, num_seeds]
                  uint32_t* const num_executed_iterations,  // [num_queries,]
                  uint32_t topk)
  {
    cudaStream_t stream = res.get_stream();
    uint32_t block_size = thread_block_size;

    SET_MC_KERNEL;
    RAFT_CUDA_TRY(
      cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
    // Initialize hash table
    const uint32_t hash_size = hashmap::get_size(hash_bitlen);
    set_value_batch(
      hashmap.data(), hash_size, utils::get_max_value<uint32_t>(), hash_size, num_queries, stream);

    dim3 block_dims(block_size, 1, 1);
    dim3 grid_dims(num_cta_per_query, num_queries, 1);
    RAFT_LOG_DEBUG("Launching kernel with %u threads, (%u, %u) blocks %lu smem",
                   block_size,
                   num_cta_per_query,
                   num_queries,
                   smem_size);
    kernel<<<grid_dims, block_dims, smem_size, stream>>>(intermediate_indices.data(),
                                                         intermediate_distances.data(),
                                                         dataset.data_handle(),
                                                         dataset.extent(1),
                                                         dataset.extent(0),
                                                         queries_ptr,
                                                         graph.data_handle(),
                                                         graph.extent(1),
                                                         num_random_samplings,
                                                         rand_xor_mask,
                                                         dev_seed_ptr,
                                                         num_seeds,
                                                         hashmap.data(),
                                                         hash_bitlen,
                                                         itopk_size,
                                                         num_parents,
                                                         min_iterations,
                                                         max_iterations,
                                                         num_executed_iterations);
    RAFT_CUDA_TRY(cudaPeekAtLastError());

    // Select the top-k results from the intermediate results
    const uint32_t num_intermediate_results = num_cta_per_query * itopk_size;
    _cuann_find_topk(topk,
                     num_queries,
                     num_intermediate_results,
                     intermediate_distances.data(),
                     num_intermediate_results,
                     intermediate_indices.data(),
                     num_intermediate_results,
                     topk_distances_ptr,
                     topk,
                     topk_indices_ptr,
                     topk,
                     topk_workspace.data(),
                     true,
                     NULL,
                     stream);
  }
};

}  // namespace multi_cta_search
}  // namespace raft::neighbors::experimental::cagra::detail

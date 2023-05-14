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
#include <rmm/device_uvector.hpp>
#include <vector>

#include "bitonic.hpp"
#include "compute_distance.hpp"
#include "device_common.hpp"
#include "hashmap.hpp"
#include "search_plan.cuh"
#include "search_single_cta_kernel.cuh"
#include "topk_by_radix.cuh"
#include "topk_for_cagra/topk_core.cuh"  // TODO replace with raft topk
#include "utils.hpp"
#include <raft/core/logger.hpp>
#include <raft/util/cuda_rt_essentials.hpp>
#include <raft/util/cudart_utils.hpp>  // RAFT_CUDA_TRY_NOT_THROW is used TODO(tfeher): consider moving this to cuda_rt_essentials.hpp

namespace raft::neighbors::experimental::cagra::detail {
namespace single_cta_search {

#define SET_KERNEL_3(                                                               \
  BLOCK_SIZE, BLOCK_COUNT, MAX_ITOPK, MAX_CANDIDATES, TOPK_BY_BITONIC_SORT, LOAD_T) \
  kernel = search_kernel<TEAM_SIZE,                                                 \
                         BLOCK_SIZE,                                                \
                         BLOCK_COUNT,                                               \
                         MAX_ITOPK,                                                 \
                         MAX_CANDIDATES,                                            \
                         TOPK_BY_BITONIC_SORT,                                      \
                         MAX_DATASET_DIM,                                           \
                         DATA_T,                                                    \
                         DISTANCE_T,                                                \
                         INDEX_T,                                                   \
                         LOAD_T>;

#define SET_KERNEL_2(BLOCK_SIZE, BLOCK_COUNT, MAX_ITOPK, MAX_CANDIDATES, TOPK_BY_BITONIC_SORT) \
  if (load_bit_length == 128) {                                                                \
    SET_KERNEL_3(BLOCK_SIZE,                                                                   \
                 BLOCK_COUNT,                                                                  \
                 MAX_ITOPK,                                                                    \
                 MAX_CANDIDATES,                                                               \
                 TOPK_BY_BITONIC_SORT,                                                         \
                 device::LOAD_128BIT_T)                                                        \
  } else if (load_bit_length == 64) {                                                          \
    SET_KERNEL_3(BLOCK_SIZE,                                                                   \
                 BLOCK_COUNT,                                                                  \
                 MAX_ITOPK,                                                                    \
                 MAX_CANDIDATES,                                                               \
                 TOPK_BY_BITONIC_SORT,                                                         \
                 device::LOAD_64BIT_T)                                                         \
  }

#define SET_KERNEL_1B(MAX_ITOPK, MAX_CANDIDATES)              \
  /* if ( block_size == 32 ) {                                \
      SET_KERNEL_2( 32, 20, MAX_ITOPK, MAX_CANDIDATES, 1 )    \
  } else */                                                   \
  if (block_size == 64) {                                     \
    SET_KERNEL_2(64, 16 /*20*/, MAX_ITOPK, MAX_CANDIDATES, 1) \
  } else if (block_size == 128) {                             \
    SET_KERNEL_2(128, 8, MAX_ITOPK, MAX_CANDIDATES, 1)        \
  } else if (block_size == 256) {                             \
    SET_KERNEL_2(256, 4, MAX_ITOPK, MAX_CANDIDATES, 1)        \
  } else if (block_size == 512) {                             \
    SET_KERNEL_2(512, 2, MAX_ITOPK, MAX_CANDIDATES, 1)        \
  } else {                                                    \
    SET_KERNEL_2(1024, 1, MAX_ITOPK, MAX_CANDIDATES, 1)       \
  }

#define SET_KERNEL_1R(MAX_ITOPK, MAX_CANDIDATES)        \
  if (block_size == 256) {                              \
    SET_KERNEL_2(256, 4, MAX_ITOPK, MAX_CANDIDATES, 0)  \
  } else if (block_size == 512) {                       \
    SET_KERNEL_2(512, 2, MAX_ITOPK, MAX_CANDIDATES, 0)  \
  } else {                                              \
    SET_KERNEL_2(1024, 1, MAX_ITOPK, MAX_CANDIDATES, 0) \
  }

#define SET_KERNEL                                                                \
  typedef void (*search_kernel_t)(INDEX_T* const result_indices_ptr,              \
                                  DISTANCE_T* const result_distances_ptr,         \
                                  const std::uint32_t top_k,                      \
                                  const DATA_T* const dataset_ptr,                \
                                  const std::size_t dataset_dim,                  \
                                  const std::size_t dataset_size,                 \
                                  const DATA_T* const queries_ptr,                \
                                  const INDEX_T* const knn_graph,                 \
                                  const std::uint32_t graph_degree,               \
                                  const unsigned num_distilation,                 \
                                  const uint64_t rand_xor_mask,                   \
                                  const INDEX_T* seed_ptr,                        \
                                  const uint32_t num_seeds,                       \
                                  std::uint32_t* const visited_hashmap_ptr,       \
                                  const std::uint32_t itopk_size,                 \
                                  const std::uint32_t num_parents,                \
                                  const std::uint32_t min_iteration,              \
                                  const std::uint32_t max_iteration,              \
                                  std::uint32_t* const num_executed_iterations,   \
                                  const std::uint32_t hash_bitlen,                \
                                  const std::uint32_t small_hash_bitlen,          \
                                  const std::uint32_t small_hash_reset_interval); \
  search_kernel_t kernel;                                                         \
  if (num_itopk_candidates <= 64) {                                               \
    constexpr unsigned max_candidates = 64;                                       \
    if (itopk_size <= 64) {                                                       \
      SET_KERNEL_1B(64, max_candidates)                                           \
    } else if (itopk_size <= 128) {                                               \
      SET_KERNEL_1B(128, max_candidates)                                          \
    } else if (itopk_size <= 256) {                                               \
      SET_KERNEL_1B(256, max_candidates)                                          \
    } else if (itopk_size <= 512) {                                               \
      SET_KERNEL_1B(512, max_candidates)                                          \
    }                                                                             \
  } else if (num_itopk_candidates <= 128) {                                       \
    constexpr unsigned max_candidates = 128;                                      \
    if (itopk_size <= 64) {                                                       \
      SET_KERNEL_1B(64, max_candidates)                                           \
    } else if (itopk_size <= 128) {                                               \
      SET_KERNEL_1B(128, max_candidates)                                          \
    } else if (itopk_size <= 256) {                                               \
      SET_KERNEL_1B(256, max_candidates)                                          \
    } else if (itopk_size <= 512) {                                               \
      SET_KERNEL_1B(512, max_candidates)                                          \
    }                                                                             \
  } else if (num_itopk_candidates <= 256) {                                       \
    constexpr unsigned max_candidates = 256;                                      \
    if (itopk_size <= 64) {                                                       \
      SET_KERNEL_1B(64, max_candidates)                                           \
    } else if (itopk_size <= 128) {                                               \
      SET_KERNEL_1B(128, max_candidates)                                          \
    } else if (itopk_size <= 256) {                                               \
      SET_KERNEL_1B(256, max_candidates)                                          \
    } else if (itopk_size <= 512) {                                               \
      SET_KERNEL_1B(512, max_candidates)                                          \
    }                                                                             \
  } else {                                                                        \
    /* Radix-based topk is used */                                                \
    if (itopk_size <= 256) {                                                      \
      SET_KERNEL_1R(256, /*to avoid build failure*/ 32)                           \
    } else if (itopk_size <= 512) {                                               \
      SET_KERNEL_1R(512, /*to avoid build failure*/ 32)                           \
    }                                                                             \
  }

template <unsigned TEAM_SIZE,
          unsigned MAX_DATASET_DIM,
          typename DATA_T,
          typename INDEX_T,
          typename DISTANCE_T>
struct search : search_plan_impl<DATA_T, INDEX_T, DISTANCE_T> {
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

  uint32_t num_itopk_candidates;

  search(raft::device_resources const& res,
         search_params params,
         int64_t dim,
         int64_t graph_degree,
         uint32_t topk)
    : search_plan_impl<DATA_T, INDEX_T, DISTANCE_T>(res, params, dim, graph_degree, topk)
  {
    set_params(res);
  }

  ~search() {}

  inline void set_params(raft::device_resources const& res)
  {
    num_itopk_candidates = num_parents * graph_degree;
    result_buffer_size   = itopk_size + num_itopk_candidates;

    typedef raft::Pow2<32> AlignBytes;
    unsigned result_buffer_size_32 = AlignBytes::roundUp(result_buffer_size);

    constexpr unsigned max_itopk = 512;
    RAFT_EXPECTS(itopk_size <= max_itopk, "itopk_size cannot be larger than %u", max_itopk);

    RAFT_LOG_DEBUG("# num_itopk_candidates: %u", num_itopk_candidates);
    RAFT_LOG_DEBUG("# num_itopk: %u", itopk_size);
    //
    // Determine the thread block size
    //
    constexpr unsigned min_block_size       = 64;  // 32 or 64
    constexpr unsigned min_block_size_radix = 256;
    constexpr unsigned max_block_size       = 1024;
    //
    const std::uint32_t topk_ws_size = 3;
    const std::uint32_t base_smem_size =
      sizeof(float) * max_dim + (sizeof(INDEX_T) + sizeof(DISTANCE_T)) * result_buffer_size_32 +
      sizeof(std::uint32_t) * hashmap::get_size(small_hash_bitlen) +
      sizeof(std::uint32_t) * num_parents + sizeof(std::uint32_t) * topk_ws_size +
      sizeof(std::uint32_t);
    smem_size = base_smem_size;
    if (num_itopk_candidates > 256) {
      // Tentatively calculate the required share memory size when radix
      // sort based topk is used, assuming the block size is the maximum.
      if (itopk_size <= 256) {
        smem_size += topk_by_radix_sort<256, max_block_size>::smem_size * sizeof(std::uint32_t);
      } else {
        smem_size += topk_by_radix_sort<512, max_block_size>::smem_size * sizeof(std::uint32_t);
      }
    }

    uint32_t block_size = thread_block_size;
    if (block_size == 0) {
      block_size = min_block_size;

      if (num_itopk_candidates > 256) {
        // radix-based topk is used.
        block_size = min_block_size_radix;

        // Internal topk values per thread must be equlal to or less than 4
        // when radix-sort block_topk is used.
        while ((block_size < max_block_size) && (max_itopk / block_size > 4)) {
          block_size *= 2;
        }
      }

      // Increase block size according to shared memory requirements.
      // If block size is 32, upper limit of shared memory size per
      // thread block is set to 4096. This is GPU generation dependent.
      constexpr unsigned ulimit_smem_size_cta32 = 4096;
      while (smem_size > ulimit_smem_size_cta32 / 32 * block_size) {
        block_size *= 2;
      }

      // Increase block size to improve GPU occupancy when batch size
      // is small, that is, number of queries is low.
      cudaDeviceProp deviceProp = res.get_device_properties();
      RAFT_LOG_DEBUG("# multiProcessorCount: %d", deviceProp.multiProcessorCount);
      while ((block_size < max_block_size) &&
             (graph_degree * num_parents * team_size >= block_size * 2) &&
             (max_queries <= (1024 / (block_size * 2)) * deviceProp.multiProcessorCount)) {
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

    // Determine load bit length
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

    if (num_itopk_candidates <= 256) {
      RAFT_LOG_DEBUG("# bitonic-sort based topk routine is used");
    } else {
      RAFT_LOG_DEBUG("# radix-sort based topk routine is used");
      smem_size = base_smem_size;
      if (itopk_size <= 256) {
        constexpr unsigned MAX_ITOPK = 256;
        if (block_size == 256) {
          constexpr unsigned BLOCK_SIZE = 256;
          smem_size += topk_by_radix_sort<MAX_ITOPK, BLOCK_SIZE>::smem_size * sizeof(std::uint32_t);
        } else if (block_size == 512) {
          constexpr unsigned BLOCK_SIZE = 512;
          smem_size += topk_by_radix_sort<MAX_ITOPK, BLOCK_SIZE>::smem_size * sizeof(std::uint32_t);
        } else {
          constexpr unsigned BLOCK_SIZE = 1024;
          smem_size += topk_by_radix_sort<MAX_ITOPK, BLOCK_SIZE>::smem_size * sizeof(std::uint32_t);
        }
      } else {
        constexpr unsigned MAX_ITOPK = 512;
        if (block_size == 256) {
          constexpr unsigned BLOCK_SIZE = 256;
          smem_size += topk_by_radix_sort<MAX_ITOPK, BLOCK_SIZE>::smem_size * sizeof(std::uint32_t);
        } else if (block_size == 512) {
          constexpr unsigned BLOCK_SIZE = 512;
          smem_size += topk_by_radix_sort<MAX_ITOPK, BLOCK_SIZE>::smem_size * sizeof(std::uint32_t);
        } else {
          constexpr unsigned BLOCK_SIZE = 1024;
          smem_size += topk_by_radix_sort<MAX_ITOPK, BLOCK_SIZE>::smem_size * sizeof(std::uint32_t);
        }
      }
    }
    RAFT_LOG_DEBUG("# smem_size: %u", smem_size);
    hashmap_size = 0;
    if (small_hash_bitlen == 0) {
      hashmap_size = sizeof(uint32_t) * max_queries * hashmap::get_size(hash_bitlen);
      hashmap.resize(hashmap_size, res.get_stream());
    }
    RAFT_LOG_DEBUG("# hashmap_size: %lu", hashmap_size);
  }

  void operator()(raft::device_resources const& res,
                  raft::device_matrix_view<const DATA_T, INDEX_T, row_major> dataset,
                  raft::device_matrix_view<const INDEX_T, INDEX_T, row_major> graph,
                  INDEX_T* const result_indices_ptr,             // [num_queries, topk]
                  DISTANCE_T* const result_distances_ptr,        // [num_queries, topk]
                  const DATA_T* const queries_ptr,               // [num_queries, dataset_dim]
                  const std::uint32_t num_queries,
                  const INDEX_T* dev_seed_ptr,                   // [num_queries, num_seeds]
                  std::uint32_t* const num_executed_iterations,  // [num_queries]
                  uint32_t topk)
  {
    cudaStream_t stream = res.get_stream();
    uint32_t block_size = thread_block_size;
    SET_KERNEL;
    RAFT_CUDA_TRY(
      cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
    dim3 thread_dims(block_size, 1, 1);
    dim3 block_dims(1, num_queries, 1);
    RAFT_LOG_DEBUG(
      "Launching kernel with %u threads, %u block %lu smem", block_size, num_queries, smem_size);
    kernel<<<block_dims, thread_dims, smem_size, stream>>>(result_indices_ptr,
                                                           result_distances_ptr,
                                                           topk,
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
                                                           itopk_size,
                                                           num_parents,
                                                           min_iterations,
                                                           max_iterations,
                                                           num_executed_iterations,
                                                           hash_bitlen,
                                                           small_hash_bitlen,
                                                           small_hash_reset_interval);
    RAFT_CUDA_TRY(cudaPeekAtLastError());
  }
};

}  // namespace single_cta_search
}  // namespace raft::neighbors::experimental::cagra::detail

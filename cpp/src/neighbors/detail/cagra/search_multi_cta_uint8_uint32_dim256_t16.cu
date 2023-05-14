
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

/*
 * NOTE: this file is generated by search_multi_cta_00_generate.py
 *
 * Make changes there and run in this directory:
 *
 * > python search_multi_cta_00_generate.py
 *
 */

#include <raft/neighbors/detail/cagra/search_multi_cta_kernel-inl.cuh>

namespace raft::neighbors::experimental::cagra::detail::multi_cta_search {
#define instantiate_multi_cta_search_kernel(TEAM_SIZE,                                   \
                                            BLOCK_SIZE,                                  \
                                            BLOCK_COUNT,                                 \
                                            MAX_ELEMENTS,                                \
                                            MAX_DATASET_DIM,                             \
                                            DATA_T,                                      \
                                            DISTANCE_T,                                  \
                                            INDEX_T,                                     \
                                            LOAD_T)                                      \
  template __global__ void search_kernel<TEAM_SIZE,                                      \
                                         BLOCK_SIZE,                                     \
                                         BLOCK_COUNT,                                    \
                                         MAX_ELEMENTS,                                   \
                                         MAX_DATASET_DIM,                                \
                                         DATA_T,                                         \
                                         DISTANCE_T,                                     \
                                         INDEX_T,                                        \
                                         LOAD_T>(INDEX_T* const result_indices_ptr,      \
                                                 DISTANCE_T* const result_distances_ptr, \
                                                 const DATA_T* const dataset_ptr,        \
                                                 const size_t dataset_dim,               \
                                                 const size_t dataset_size,              \
                                                 const DATA_T* const queries_ptr,        \
                                                 const INDEX_T* const knn_graph,         \
                                                 const uint32_t graph_degree,            \
                                                 const unsigned num_distilation,         \
                                                 const uint64_t rand_xor_mask,           \
                                                 const INDEX_T* seed_ptr,                \
                                                 const uint32_t num_seeds,               \
                                                 uint32_t* const visited_hashmap_ptr,    \
                                                 const uint32_t hash_bitlen,             \
                                                 const uint32_t itopk_size,              \
                                                 const uint32_t num_parents,             \
                                                 const uint32_t min_iteration,           \
                                                 const uint32_t max_iteration,           \
                                                 uint32_t* const num_executed_iterations);

instantiate_multi_cta_search_kernel(16, 64, 16, 64, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 64, 16, 128, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 64, 16, 256, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 128, 8, 64, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 128, 8, 128, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 128, 8, 256, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 256, 4, 64, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 256, 4, 128, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 256, 4, 256, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 512, 2, 64, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 512, 2, 128, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 512, 2, 256, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 1024, 1, 64, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 1024, 1, 128, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 1024, 1, 256, 256, uint8_t, float, uint32_t, uint4);
instantiate_multi_cta_search_kernel(16, 64, 16, 64, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 64, 16, 128, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 64, 16, 256, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 128, 8, 64, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 128, 8, 128, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 128, 8, 256, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 256, 4, 64, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 256, 4, 128, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 256, 4, 256, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 512, 2, 64, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 512, 2, 128, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 512, 2, 256, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 1024, 1, 64, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 1024, 1, 128, 256, uint8_t, float, uint32_t, uint64_t);
instantiate_multi_cta_search_kernel(16, 1024, 1, 256, 256, uint8_t, float, uint32_t, uint64_t);

#undef instantiate_multi_cta_search_kernel

}  // namespace raft::neighbors::experimental::cagra::detail::multi_cta_search

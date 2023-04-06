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
#ifndef RAFT_DISABLE_CUDA
#include <cuda_runtime_api.h>
#endif

namespace raft {
#ifndef RAFT_DISABLE_CUDA
using execution_stream = cudaStream_t;
#else
using execution_stream = int;
#endif
inline void synchronize(execution_stream stream) {
#ifndef RAFT_DISABLE_CUDA
  cudaStreamSynchronize(stream);
#endif
}
}
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
#include "execution_device_id_base.hpp"
#include <raft/core/device_type.hpp>

namespace raft {
namespace detail {
template <>
struct execution_device_id<raft::device_type::cpu> {
  using value_type = int;
  execution_device_id() : id_{value_type{}} {};
  execution_device_id(value_type dev_id) : id_{dev_id} {};

  auto value() const noexcept { return id_; }
 private:
  value_type id_;
};
}
}
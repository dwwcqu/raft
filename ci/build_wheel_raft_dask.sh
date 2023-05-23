#!/bin/bash
# Copyright (c) 2023, NVIDIA CORPORATION.

pyenv global ${RAPIDS_PY_VERSION}

# Set up skbuild options. Enable sccache in skbuild config options
export SKBUILD_CONFIGURE_OPTIONS="-DRAFT_BUILD_WHEELS=ON -DDETECT_CONDA_ENV=OFF -DFIND_RAFT_CPP=OFF -DCMAKE_C_COMPILER_LAUNCHER=/usr/bin/sccache -DCMAKE_CXX_COMPILER_LAUNCHER=/usr/bin/sccache -DCMAKE_CUDA_COMPILER_LAUNCHER=/usr/bin/sccache"

export RAPIDS_BEFORE_WHEEL="RAPIDS_PY_WHEEL_NAME=pylibraft_${RAPIDS_PY_CUDA_SUFFIX} rapids-download-wheels-from-s3 ./local-pylibraft && python -m pip install --no-deps ./local-pylibraft/pylibraft*.whl"

./build_wheel.sh raft_dask python/raft-dask

PROJECT := gemmbench

CXX ?= g++
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra -Wpedantic -fopenmp

INCLUDES := -Iinclude

BUILD_DIR := build
OBJ_DIR := $(BUILD_DIR)/obj

# CUDA (optional): set USE_CUDA=0 for CPU-only build.
USE_CUDA ?= 1
CUDA_HOME ?= /usr/local/cuda
NVCC ?= $(CUDA_HOME)/bin/nvcc
CUDA_ARCH ?= sm_75
# nvcc host compiler: prefer g++-11 when default g++ is too new for bundled headers.
NVCC_HOST_CXX ?= $(shell command -v g++-11 2>/dev/null || command -v g++-10 2>/dev/null || command -v g++)

NVCCFLAGS := -O3 -std=c++17 -Iinclude -lineinfo -allow-unsupported-compiler -ccbin $(NVCC_HOST_CXX)

LIB_SRCS_CPP := \
  src/gemm_kernels.cpp \
  src/matrix.cpp \
  src/validate.cpp

BIN_SRCS := \
  src/main.cpp

LIB_OBJS := $(patsubst src/%.cpp,$(OBJ_DIR)/%.o,$(LIB_SRCS_CPP))
BIN_OBJS := $(patsubst src/%.cpp,$(OBJ_DIR)/%.o,$(BIN_SRCS))

BIN := $(BUILD_DIR)/$(PROJECT)

HAVE_NVCC := $(shell test -x "$(NVCC)" && echo 1 || echo 0)

ifeq ($(USE_CUDA),1)
ifeq ($(HAVE_NVCC),1)
  CXXFLAGS += -DGEMMBENCH_USE_CUDA
  LIB_OBJS += $(OBJ_DIR)/gemm_gpu.o
  LDFLAGS += -L$(CUDA_HOME)/lib64 -lcudart -Wl,-rpath,$(CUDA_HOME)/lib64
  NVCCFLAGS += -arch=$(CUDA_ARCH)
else
  $(warning nvcc not found at $(NVCC); building CPU-only. Set CUDA_HOME or USE_CUDA=0.)
endif
endif

.PHONY: all clean
all: $(BIN)

$(BIN): $(LIB_OBJS) $(BIN_OBJS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $^ -o $@ $(LDFLAGS)

$(OBJ_DIR)/%.o: src/%.cpp | $(OBJ_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

$(OBJ_DIR)/gemm_gpu.o: src/gemm_gpu.cu | $(OBJ_DIR)
	$(NVCC) $(NVCCFLAGS) -c $< -o $@

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

clean:
	rm -rf $(BUILD_DIR)

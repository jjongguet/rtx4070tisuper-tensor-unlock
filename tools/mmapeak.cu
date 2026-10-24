// mmapeak: raw tensor-core microbenchmark for Ada tensor-rate gating checks.
// Issues back-to-back mma.sync instructions on register operands only, so the
// measured rate is instruction throughput, not memory or cuBLAS heuristics.
// Each variant fixes its own accumulate mode in the PTX guard.

#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>

#define GROUPS   8   // independent accumulator sets: hides mma latency
#define UNROLL   8   // mma per accumulator set per loop iteration
#define THREADS  256

// FLOP per mma instruction = 2 * M * N * K
__device__ __forceinline__ void dump(float *out, float v) {
    if (threadIdx.x == 1024) out[0] = v;   // never true: keeps stores alive
}

// ---------------- FP16 -> FP32 accumulate (gated path) ----------------
__global__ void k_f16_f32(float *out, int iters) {
    unsigned a0 = 0x3c003c00u, a1 = a0, a2 = a0, a3 = a0;
    unsigned b0 = 0x3c003c00u, b1 = b0;
    float c[GROUPS][4];
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) { c[g][0]=c[g][1]=c[g][2]=c[g][3]=0.f; }
    for (int i = 0; i < iters; i++) {
        #pragma unroll
        for (int u = 0; u < UNROLL; u++) {
            #pragma unroll
            for (int g = 0; g < GROUPS; g++) {
                asm volatile(
                  "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32 "
                  "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};\n"
                  : "+f"(c[g][0]), "+f"(c[g][1]), "+f"(c[g][2]), "+f"(c[g][3])
                  : "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(b0), "r"(b1));
            }
        }
    }
    float s = 0.f;
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) s += c[g][0]+c[g][1]+c[g][2]+c[g][3];
    dump(out, s);
}

// ---------------- FP16 -> FP16 accumulate (ungated control) ----------------
__global__ void k_f16_f16(float *out, int iters) {
    unsigned a0 = 0x3c003c00u, a1 = a0, a2 = a0, a3 = a0;
    unsigned b0 = 0x3c003c00u, b1 = b0;
    unsigned c[GROUPS][2];
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) { c[g][0]=0u; c[g][1]=0u; }
    for (int i = 0; i < iters; i++) {
        #pragma unroll
        for (int u = 0; u < UNROLL; u++) {
            #pragma unroll
            for (int g = 0; g < GROUPS; g++) {
                asm volatile(
                  "mma.sync.aligned.m16n8k16.row.col.f16.f16.f16.f16 "
                  "{%0,%1}, {%2,%3,%4,%5}, {%6,%7}, {%0,%1};\n"
                  : "+r"(c[g][0]), "+r"(c[g][1])
                  : "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(b0), "r"(b1));
            }
        }
    }
    unsigned s = 0u;
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) s += c[g][0]+c[g][1];
    dump(out, (float)s);
}

// ---------------- BF16 -> FP32 accumulate (gated path) ----------------
__global__ void k_bf16_f32(float *out, int iters) {
    unsigned a0 = 0x3f803f80u, a1 = a0, a2 = a0, a3 = a0;
    unsigned b0 = 0x3f803f80u, b1 = b0;
    float c[GROUPS][4];
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) { c[g][0]=c[g][1]=c[g][2]=c[g][3]=0.f; }
    for (int i = 0; i < iters; i++) {
        #pragma unroll
        for (int u = 0; u < UNROLL; u++) {
            #pragma unroll
            for (int g = 0; g < GROUPS; g++) {
                asm volatile(
                  "mma.sync.aligned.m16n8k16.row.col.f32.bf16.bf16.f32 "
                  "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};\n"
                  : "+f"(c[g][0]), "+f"(c[g][1]), "+f"(c[g][2]), "+f"(c[g][3])
                  : "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(b0), "r"(b1));
            }
        }
    }
    float s = 0.f;
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) s += c[g][0]+c[g][1]+c[g][2]+c[g][3];
    dump(out, s);
}

// ---------------- TF32 -> FP32 accumulate (gated path) ----------------
__global__ void k_tf32(float *out, int iters) {
    unsigned a0 = 0x3f800000u, a1 = a0, a2 = a0, a3 = a0;
    unsigned b0 = 0x3f800000u, b1 = b0;
    float c[GROUPS][4];
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) { c[g][0]=c[g][1]=c[g][2]=c[g][3]=0.f; }
    for (int i = 0; i < iters; i++) {
        #pragma unroll
        for (int u = 0; u < UNROLL; u++) {
            #pragma unroll
            for (int g = 0; g < GROUPS; g++) {
                asm volatile(
                  "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32 "
                  "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};\n"
                  : "+f"(c[g][0]), "+f"(c[g][1]), "+f"(c[g][2]), "+f"(c[g][3])
                  : "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(b0), "r"(b1));
            }
        }
    }
    float s = 0.f;
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) s += c[g][0]+c[g][1]+c[g][2]+c[g][3];
    dump(out, s);
}

// ---------------- FP8 E4M3 -> FP32 accumulate (gated path) ----------------
__global__ void k_fp8(float *out, int iters) {
    unsigned a0 = 0x3c3c3c3cu, a1 = a0, a2 = a0, a3 = a0;
    unsigned b0 = 0x3c3c3c3cu, b1 = b0;
    float c[GROUPS][4];
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) { c[g][0]=c[g][1]=c[g][2]=c[g][3]=0.f; }
    for (int i = 0; i < iters; i++) {
        #pragma unroll
        for (int u = 0; u < UNROLL; u++) {
            #pragma unroll
            for (int g = 0; g < GROUPS; g++) {
                asm volatile(
                  "mma.sync.aligned.m16n8k32.row.col.f32.e4m3.e4m3.f32 "
                  "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};\n"
                  : "+f"(c[g][0]), "+f"(c[g][1]), "+f"(c[g][2]), "+f"(c[g][3])
                  : "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(b0), "r"(b1));
            }
        }
    }
    float s = 0.f;
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) s += c[g][0]+c[g][1]+c[g][2]+c[g][3];
    dump(out, s);
}

// ---------------- FFMA (never gated: scalar FP32 control) ----------------
__global__ void k_ffma(float *out, int iters) {
    float a = 1.000001f, b = 0.999999f;
    float c[GROUPS][4];
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) { c[g][0]=c[g][1]=c[g][2]=c[g][3]=0.f; }
    for (int i = 0; i < iters; i++) {
        #pragma unroll
        for (int u = 0; u < UNROLL; u++) {
            #pragma unroll
            for (int g = 0; g < GROUPS; g++) {
                #pragma unroll
                for (int e = 0; e < 4; e++) c[g][e] = fmaf(a, c[g][e], b);
            }
        }
    }
    float s = 0.f;
    #pragma unroll
    for (int g = 0; g < GROUPS; g++) s += c[g][0]+c[g][1]+c[g][2]+c[g][3];
    dump(out, s);
}

// ---------------------------------------------------------------------------

struct Item { const char *name; void (*fn)(float *, int); double flop_per_mma; };

static double time_kernel(Item it, int sm, int iters, int reps) {
    float *out = nullptr;
    cudaMalloc(&out, sizeof(float));
    int blocks = sm * 2;                       // saturate the SMs
    dim3 grid(blocks), block(THREADS);
    for (int i = 0; i < 3; i++) it.fn<<<grid, block>>>(out, iters);   // warm
    cudaDeviceSynchronize();

    cudaEvent_t s, e;
    cudaEventCreate(&s); cudaEventCreate(&e);
    cudaEventRecord(s);
    for (int i = 0; i < reps; i++) it.fn<<<grid, block>>>(out, iters);
    cudaEventRecord(e);
    cudaEventSynchronize(e);
    float ms = 0.f;
    cudaEventElapsedTime(&ms, s, e);

    double warps = (double)blocks * (THREADS / 32);
    double mma_total = warps * (double)iters * UNROLL * GROUPS * reps;
    double flops = mma_total * it.flop_per_mma;
    cudaFree(out);
    cudaEventDestroy(s); cudaEventDestroy(e);
    return flops / (ms * 1e-3) / 1e12;   // TFLOPS
}

int main(int argc, char **argv) {
    int iters = (argc > 1) ? atoi(argv[1]) : 2048;
    int reps  = (argc > 2) ? atoi(argv[2]) : 5;

    cudaDeviceProp p;
    cudaGetDeviceProperties(&p, 0);
    printf("GPU  : %s\n", p.name);
    int clk = 0;
    cudaDeviceGetAttribute(&clk, cudaDevAttrClockRate, 0);
    printf("SM   : %d   cc=%d.%d   clock(max)=%d MHz\n",
           p.multiProcessorCount, p.major, p.minor, clk / 1000);
    printf("iters=%d reps=%d warps/block=%d\n\n", iters, reps, THREADS / 32);

    Item items[] = {
        {"FP16 -> FP32acc", k_f16_f32,  2.0 * 16 * 8 * 16},
        {"FP16 -> FP16acc", k_f16_f16,  2.0 * 16 * 8 * 16},
        {"BF16 -> FP32acc", k_bf16_f32, 2.0 * 16 * 8 * 16},
        {"TF32 -> FP32acc", k_tf32,     2.0 * 16 * 8 * 8},
        {"FP8  -> FP32acc", k_fp8,      2.0 * 16 * 8 * 32},
        {"FFMA (fp32)    ", k_ffma,     (double)(GROUPS * 4 * 2)},
    };

    double res[6];
    for (int i = 0; i < 6; i++) {
        double best = 0.0;
        for (int r = 0; r < 3; r++) {
            double t = time_kernel(items[i], p.multiProcessorCount, iters, reps);
            if (t > best) best = t;
        }
        res[i] = best;
        printf("  %-16s %8.2f TFLOPS\n", items[i].name, best);
    }

    printf("\n  ratio FP16/FP32acc ÷ FP16/FP16acc = %.3f   (locked ~0.5, unlocked ~1.0)\n",
           res[0] / res[1]);
    printf("  ratio BF16/FP32acc ÷ FP16/FP16acc = %.3f\n", res[2] / res[1]);
    return 0;
}

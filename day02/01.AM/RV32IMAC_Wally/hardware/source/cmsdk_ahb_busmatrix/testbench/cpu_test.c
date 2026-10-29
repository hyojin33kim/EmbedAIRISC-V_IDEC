// 실제 CPU로 MMIO와 공유 SRAM 및 NPU DMA와 PLIC 연결을 검증한다.
#include <stdint.h>
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define NPU(off) REG(0x10080000u + (off))
#define GPIO REG(0x1006000cu)

static void require(int ok) {
  if (!ok) { GPIO = 0xbad00001u; for (;;) {} }
}

#ifndef CPU_ONLY
static const uint8_t input[131] __attribute__((aligned(64))) = {[0 ... 130] = 200};
static const uint8_t weight[385] __attribute__((aligned(64))) = {
  [1 ... 128] = 1, [129 ... 256] = 255, [257 ... 384] = 2
};
static const int32_t qparam[9] __attribute__((aligned(64))) = {0,1,7, 0,1,8, -3,1,9};
static volatile uint8_t output[192] __attribute__((aligned(64))) = {[0 ... 191] = 0xa5};
static const volatile uint32_t traffic[4096] __attribute__((aligned(64))) = {[0 ... 4095] = 0x33};

static void npu_test(void) {
  require(NPU(0) == 0x544e5055u && NPU(4) == 0x00010000u);
  REG(0x0c00003c) = 1;
  REG(0x0c002000) = 1u << 15;
  REG(0x0c200000) = 0;
  for (unsigned i=0; i<sizeof output; i+=64)
    __asm__ volatile("cbo.flush 0(%0)" :: "r"(&output[i]) : "memory");
  __asm__ volatile("fence rw,rw" ::: "memory");
  NPU(0x10)=3; NPU(0x20)=1;
  NPU(0x24)=(uintptr_t)&input[1]; NPU(0x28)=(uintptr_t)&weight[1];
  NPU(0x2c)=(uintptr_t)&output[65]; NPU(0x30)=(uintptr_t)qparam;
  NPU(0x34)=0x00010420; NPU(0x38)=3; NPU(0x3c)=0x8078;
  __asm__ volatile("fence rw,rw" ::: "memory");
  NPU(8)=1;
  uint32_t sum=0;
  for (unsigned i=0;i<4096;i+=16) sum+=traffic[i];
  require(sum == 256u*0x33u);
  unsigned timeout=100000;
  while (NPU(0x0c)&1) require(--timeout != 0);
  require(NPU(0x0c)==2 && NPU(0x14)==0 && NPU(0x1c)>0);
  __asm__ volatile("fence rw,rw" ::: "memory");
  for (unsigned i=0;i<sizeof output;i+=64)
    __asm__ volatile("cbo.inval 0(%0)" :: "r"(&output[i]) : "memory");
  __asm__ volatile("fence rw,rw" ::: "memory");
  for (unsigned i=0;i<sizeof output;i++) {
    uint8_t expected=i==65 ? 208 : (i==66 ? 88 : (i==67 ? 228 : 0xa5));
    require(output[i]==expected);
  }
  require(REG(0x0c001000)&(1u<<15));
  require(REG(0x0c200004)==15);
  NPU(0x0c)=2; REG(0x0c200004)=15;
  require(NPU(0x0c)==0);
}
#endif

int main(void) {
  REG(0x10060008)=0xffffffffu;
  volatile uint32_t sum=0;
  for (unsigned i=0;i<100;i++) sum+=i;
  require(sum==4950);
#ifndef CPU_ONLY
  npu_test();
#endif
  GPIO=0x600dcafeu;
  for (;;) {}
}

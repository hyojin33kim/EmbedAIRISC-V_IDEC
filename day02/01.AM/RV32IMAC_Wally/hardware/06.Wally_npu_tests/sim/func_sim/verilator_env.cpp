// Match the existing Wally testbench's Verilator DPI environment accessor.
#include <cstdlib>
#include <cstdio>

namespace {
struct LineBufferedLog {
    LineBufferedLog() { std::setvbuf(stdout, nullptr, _IOLBF, 0); }
} line_buffered_log;
}

extern "C" const char* getenvval(const char* name) {
    const char* value = std::getenv(name);
    return value ? value : "";
}

#include <cstdlib>

// DPI-C adapter used by the Wally SystemVerilog testbench.
extern "C" const char* getenvval(const char* name) {
    const char* value = std::getenv(name);
    return value ? value : "";
}

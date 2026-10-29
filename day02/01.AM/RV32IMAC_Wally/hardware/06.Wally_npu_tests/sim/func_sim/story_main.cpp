// Trace only top-level observation aliases, then finish the complete regression.
#include "Vtestbench.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#include <cstdio>
#include <memory>
#include <string>

int main(int argc, char** argv) {
    auto context=std::make_unique<VerilatedContext>();
    context->commandArgs(argc,argv);
    context->traceEverOn(true);
    auto model=std::make_unique<Vtestbench>(context.get());
    auto trace=std::make_unique<VerilatedFstC>();
    model->trace(trace.get(),1);
    std::string path="first_layer.fst";
    const std::string prefix="+STORY_FILE=";
    for (int i=1;i<argc;++i) {
        const std::string arg=argv[i];
        if (arg.rfind(prefix,0)==0) path=arg.substr(prefix.size());
    }
    trace->open(path.c_str());
    bool closed=false;
    while (!context->gotFinish()) {
        model->eval();
        if (!closed) {
            trace->dump(context->time());
            if (!model->story_capture) {
                trace->flush();
                closed=true;
                std::printf("[WAVE] first-layer capture ended at %llu ps: %s\n",
                            static_cast<unsigned long long>(context->time()),path.c_str());
            }
        }
        if (!model->eventsPending()) break;
        context->time(model->nextTimeSlot());
    }
    model->final();
    trace->flush();
    trace->close();
    return 0;
}

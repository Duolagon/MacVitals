#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_BUILD="$PWD/.build/regression"
mkdir -p "$TEST_BUILD/CMetrics"
cat > "$TEST_BUILD/CMetrics/module.modulemap" <<MODULE
module CMetrics {
    header "$PWD/Sources/CMetrics/include/CMetrics.h"
    export *
}
MODULE
clang -c Sources/CMetrics/CMetrics.c -I Sources/CMetrics/include -o "$TEST_BUILD/CMetrics.o"
clang -c Sources/CMetrics/AgentMetrics.c -I Sources/CMetrics/include -o "$TEST_BUILD/AgentMetrics.o"
swiftc -I "$TEST_BUILD/CMetrics" Sources/MacVitals/AgentMonitor.swift Sources/MacVitals/AgentProcessSource.swift Sources/MacVitals/SamplingPolicy.swift Sources/MacVitals/AgentInspector.swift Sources/MacVitals/AgentsView.swift Sources/MacVitals/AgentsController.swift Sources/MacVitals/NetworkSampler.swift Sources/MacVitals/MetricsFormat.swift Sources/MacVitals/StatusBarText.swift Sources/MacVitals/SystemMonitor.swift Sources/MacVitals/MetricsSupport.swift Sources/MacVitals/Dashboard.swift Sources/MacVitals/Details.swift Sources/MacVitals/PowerMetrics.swift Tests/main.swift "$TEST_BUILD/CMetrics.o" "$TEST_BUILD/AgentMetrics.o" -framework AppKit -framework IOKit -framework SystemConfiguration -o "$TEST_BUILD/checks"
"$TEST_BUILD/checks"

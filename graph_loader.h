#pragma once
#include <vector>
#include <string>
#include <fstream>
#include <sstream>
#include <chrono>
#include <stdexcept>
#include <algorithm>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif

// graph data structures used across all implementations

struct Edge {
    int src, dst;
};

// forward csr: row[v]..row[v+1]-1 give out-neighbours of v
struct CSR {
    int n;
    long long m;
    std::vector<long long> row;
    std::vector<int>       col;
    std::vector<int>       outdeg;
};

// coo stores edges as a flat array alongside per-vertex out-degrees.
// easier to build than csr and good enough for the partitioned implementations
// which re-bucket edges by partition anyway.
struct EdgeCOO {
    int src, dst;
};

struct COO {
    int n;
    long long m;
    std::vector<EdgeCOO> edges;
    std::vector<int>     outdeg;
};

// wall-clock timer that returns elapsed time in milliseconds
struct Timer {
    std::chrono::high_resolution_clock::time_point t0;
    void start() { t0 = std::chrono::high_resolution_clock::now(); }
    double elapsedMs() const {
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }
};

// reads a space-separated edge list from disk, skipping comment lines (starting with '#').
// vertex count is inferred as max(vertex_id) + 1.
static std::vector<Edge> loadEdgeList(const std::string& filename, int& n_out) {
    std::ifstream f(filename);
    if (!f.is_open()) throw std::runtime_error("cannot open: " + filename);

    std::vector<Edge> edges;
    edges.reserve(1 << 23);
    int maxV = 0;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        int u, v;
        if (!(ss >> u >> v)) continue;
        edges.push_back({u, v});
        maxV = std::max(maxV, std::max(u, v));
    }
    n_out = maxV + 1;
    return edges;
}

// builds a forward csr where row[v]..row[v+1]-1 are out-neighbours of v.
// used by the naive baseline which needs to count out-degrees cheaply.
static CSR buildCSR(const std::vector<Edge>& edges, int n) {
    CSR g;
    g.n = n;
    g.m = (long long)edges.size();
    g.row.assign(n + 1, 0);
    g.outdeg.assign(n, 0);

    for (auto& e : edges) g.outdeg[e.src]++;
    g.row[0] = 0;
    for (int i = 0; i < n; i++) g.row[i + 1] = g.row[i] + g.outdeg[i];

    g.col.resize(g.m);
    // pos[] acts as write cursors into col[], one per row
    std::vector<long long> pos(g.row.begin(), g.row.end());
    for (auto& e : edges) g.col[pos[e.src]++] = e.dst;

    return g;
}

// builds a coo from the flat edge list, also computing out-degrees
static COO buildCOO(const std::vector<Edge>& edges, int n) {
    COO g;
    g.n = n;
    g.m = (long long)edges.size();
    g.outdeg.assign(n, 0);
    g.edges.reserve(edges.size());
    for (auto& e : edges) {
        g.edges.push_back({e.src, e.dst});
        g.outdeg[e.src]++;
    }
    return g;
}

// computes how many vertices fit in one core's share of l2 cache.
// the partitioned implementations use this to size each partition so the
// working set stays warm in l2 during scatter, avoiding dram traffic.
static int computePartitionSize(int nthreads) {
    size_t l2 = 0;
#if defined(__APPLE__)
    {
        size_t sz = sizeof(l2);
        sysctlbyname("hw.l2cachesize", &l2, &sz, nullptr, 0);
    }
#else
    // linux exposes per-core cache sizes through sysfs
    {
        std::ifstream f("/sys/devices/system/cpu/cpu0/cache/index2/size");
        if (f) {
            std::string s; f >> s;
            size_t val = std::stoull(s);
            if (!s.empty() && (s.back() == 'K' || s.back() == 'k')) val *= 1024;
            else if (!s.empty() && (s.back() == 'M' || s.back() == 'm')) val *= 1024 * 1024;
            l2 = val;
        }
    }
#endif
    if (l2 == 0) l2 = 4 * 1024 * 1024; // fall back to 4 MB if detection fails
    size_t perThread = l2 / (size_t)nthreads;
    // 12 bytes per vertex: 8 for the pr double + 4 for the outdeg int
    int m = (int)(perThread / 12);
    if (m < 1024) m = 1024;
    return m;
}

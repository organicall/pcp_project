# Uses Apple clang + Homebrew libomp: brew install libomp
LIBOMP   = $(shell brew --prefix libomp)
CXX      = clang++
CXXFLAGS = -O3 -std=c++17 -Xpreprocessor -fopenmp \
           -I$(LIBOMP)/include -L$(LIBOMP)/lib -lomp
TARGETS  = pagerank_sequential pagerank_paper1 pagerank_paper1_improved pagerank_paper1_improved_2 pagerank_paper1_improved_3 pagerank_paper1_improved_4

.PHONY: all clean

all: $(TARGETS)

pagerank_sequential: pagerank_sequential.cpp graph_loader.h
	$(CXX) $(CXXFLAGS) -o $@ $<

pagerank_paper1: pagerank_paper1.cpp graph_loader.h
	$(CXX) $(CXXFLAGS) -o $@ $<

pagerank_paper1_improved: pagerank_paper1_improved.cpp graph_loader.h
	$(CXX) $(CXXFLAGS) -o $@ $<

pagerank_paper1_improved_2: pagerank_paper1_improved_2.cpp graph_loader.h
	$(CXX) $(CXXFLAGS) -o $@ $<

pagerank_paper1_improved_3: pagerank_paper1_improved_3.cpp graph_loader.h
	$(CXX) $(CXXFLAGS) -o $@ $<

pagerank_paper1_improved_4: pagerank_paper1_improved_4.cpp graph_loader.h
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -f $(TARGETS)

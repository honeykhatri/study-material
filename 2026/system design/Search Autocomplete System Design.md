# **System Design: Search Autocomplete System**

## **1\. Requirements & Scope**

### **Functional Requirements**

> 1. **Prefix-Based Matching:** As a user types a query into a search bar, the system returns a list of up to ![][image1] to ![][image2] relevant completion suggestions based on the matching prefix.  
> 2. **Frequency-Based Ranking:** Autocomplete suggestions must be ordered by popularity/frequency, incorporating recent search trends and historical volume.  
> 3. **Multi-Language & Unicode Support:** Support ASCII, UTF-8 non-English scripts, spaces, and special characters.  
> 4. **Offensive Term Filtering:** Automatically filter out hate speech, explicit content, and blacklisted terms before suggestions reach the user.

### **Non-Functional Requirements**

> 1. **Ultra-Low Latency:** Latency must be sub\-![][image3] end-to-end (typically targeting ![][image4] server-side response) to ensure smooth real-time typing feedback.  
> 2. **High Scalability & Throughput:** Support up to ![][image5] Queries Per Second (QPS) at peak search times worldwide.  
> 3. **High Availability & Fault Tolerance:** The autocomplete engine must remain available even during background trie updates or node failures. Degradation should fail open (e.g., return cached static trends) rather than failing the search input entirely.  
> 4. **Data Freshness:** New trending search queries should be reflected in autocomplete suggestions within minutes to a few hours depending on the pipeline configuration.

## **2\. High-Level Architecture**

                                      \+-----------------------+  
                                      |    Client Browser /   |  
                                      |    Mobile Application |  
                                      \+-----------+-----------+  
                                                  |  
                                            (Debounced HTTP)  
                                                  v  
                                      \+-----------------------+  
                                      |  API Gateway / CDN    |  
                                      \+-----------+-----------+  
                                                  |  
                                                  v  
                                      \+-----------------------+  
                                      |  Autocomplete Service |  
                                      |     (Query API)       |  
                                      \+-----+-----------+-----+  
                                            |           |  
                 \+--------------------------+           \+--------------------------+  
                 |                                                                 |  
                 v                                                                 v  
  \+-----------------------------+                                   \+-----------------------------+  
  |    Trie Serving Cluster     |                                   |     Redis Cache Cluster     |  
  | (In-Memory Pre-computed Trie|                                   |  (Top-K Prefix Result Cache)|  
  |    Nodes with Top-K Lists)  |                                   |                             |  
  \+-----------------------------+                                   \+-----------------------------+  
                 ^                                                                 ^  
                 | (Snapshot Swap)                                                 |  
  \+--------------+--------------+                                                  |  
  |  Trie Building / Worker Service                                                |  
  \+--------------+--------------+                                                  |  
                 ^                                                                 |  
                 |                                                                 |  
  \+--------------+--------------+                                                  |  
  | Distributed Analytics Engine|                                                  |  
  |  (Kafka \-\> Flink / Spark)   |--------------------------------------------------+  
  \+-----------------------------+

## **3\. Deep Dive: Key Technical Components**

### **A. Core Data Structure: Optimized Trie Architecture**

A standard **Trie** (Prefix Tree) allows ![][image6] retrieval of node references for a prefix of length ![][image7]. However, finding the top ![][image8] most popular terms under that prefix in a naive trie requires traversing all descendant nodes, yielding a time complexity of:  
![][image9]where ![][image10] is the total number of descendant nodes under the prefix and ![][image11] is the number of complete words.

#### **1\. Pre-computed Top\-![][image8] Optimization at Each Node**

To achieve sub\-![][image3] responses, each Trie node stores a pre-computed array/list of its top ![][image8] search terms along with their scores.  
                  (Root)  
                 /      \\  
                c        m  
               /          \\  
            (a)            (a)  
          /    \\             \\  
        (t)    (r)           (c)  
      \[cat:50\] \[car:100\]    \[mac:200\]

With pre-computed Top\-![][image8] elements stored directly inside the node structure:  
![][image12]The lookup cost becomes independent of the total subtree size ![][image10], reducing latency dramatically.

#### **2\. Node Memory Layout Definition**

{  
  "char": "a",  
  "is\_end\_of\_word": false,  
  "top\_k": \[  
    { "term": "apple", "score": 98500 },  
    { "term": "amazon", "score": 87200 },  
    { "term": "airbnb", "score": 65400 }  
  \],  
  "children": {  
    "p": "NodeRef\_123",  
    "m": "NodeRef\_124"  
  }  
}

#### **3\. Memory Optimization Techniques**

> 1. **Compact Prefix Tree / Radix Tree:** Merge single-child chains (e.g., "a" ![][image13] "u" ![][image13] "t" ![][image13] "o" merged into a single node "auto") to reduce pointer overhead.  
> 2. **Ternary Search Tree (TST):** Uses 3 pointers (left, equal, right) per node instead of dynamic hash maps/arrays for character lookup, significantly cutting memory allocations in C++/Rust implementations.

### **B. Frequency-Based Ranking & Scoring Algorithm**

Simple raw occurrence counts lead to stale results. We apply a **time-decayed frequency scoring function** so that recent searches carry higher weight than old historical volume.

#### **Time-Decay Scoring Formula**

Let ![][image14] be the count of searches at time ![][image15], and ![][image16] be the current timestamp. The decaying score ![][image17] is computed as:  
![][image18]where ![][image19] is the decay constant controlling how fast older searches lose priority:  
![][image20]For example, with a half-life ![][image21], queries from yesterday lose ![][image22] of their scoring weight compared to queries today.

#### **Personalization & Context Multipliers**

The final score ![][image23] presented to the ranking engine incorporates user locale and contextual signals:

> * ![][image24]![][image25]: Boost factor if search volume originates from the user's country/city.  
> * ![][image26]: Boost factor matching user UI language preferences.

### **C. Low-Latency Query Pipeline & Multi-Tier Caching**

To scale to ![][image5] QPS, we minimize computation per keystroke via client-side, edge, and server-side caching.  
Client Input ──► \[Client Debounce (50ms)\] ──► \[Browser Cache\] ──► \[CDN Edge Cache\] ──► \[Redis Cluster\] ──► \[Trie Service\]

#### **1\. Client-Side Debouncing & Caching**

> * **Debouncing:** Delay firing the network request by ![][image27] after the user stops typing a character.  
> * **In-Memory Browser Cache:** Cache completed prefix requests locally in an LRU browser map for the duration of the search session. If a user hits backspace (e.g., typing "mac" then back to "ma"), results load instantly from local memory.

#### **2\. Multi-Level Server Caching Strategy**

| Tier | Technology | TTL | Invalidation Trigger |
| :---- | :---- | :---- | :---- |
| **Browser Cache** | Local JavaScript LRU Map | ![][image28] | Session end or size cap (![][image29] queries). |
| **CDN / Edge** | Cloudflare / CloudFront | ![][image30] | Dynamic purge or cache header expiration. |
| **KV Cache** | Redis Cluster | ![][image31] | Updated via background pipeline when trie changes. |
| **Serving Trie** | In-Memory Sharded Trie | Continuous | Atomic snapshot pointer swap. |

### **D. Offline Trie Building & Real-Time Aggregation Pipeline**

Updating a massive, heavily read Trie directly in place causes severe read-write lock contention. Instead, building and updating trie instances is decoupled into an asynchronous stream and batch processing pipeline.  
                                  \+-------------------+  
                                  |   Search Logs /   |  
                                  | Client Click Events|  
                                  \+---------+---------+  
                                            |  
                                            v  
                                  \+-------------------+  
                                  |   Apache Kafka    |  
                                  \+---------+---------+  
                                            |  
                         \+------------------+------------------+  
                         |                                     |  
                         v                                     v  
           \+---------------------------+         \+---------------------------+  
           | Stream Processor (Flink)  |         |  Batch Processor (Spark)  |  
           | Real-time Trending Signals|         |  Daily Aggregations &     |  
           | (Sliding Window 10 mins)  |         |  Full Trie Reconstruction |  
           \+-------------+-------------+         \+-------------+-------------+  
                         |                                     |  
                         v                                     v  
           \+---------------------------+         \+---------------------------+  
           | Redis Trending Key Store  |         |   HDFS / S3 Storage       |  
           \+-------------+-------------+         \+-------------+-------------+  
                         |                                     |  
                         \+------------------+------------------+  
                                            |  
                                            v  
                                  \+-------------------+  
                                  | Trie Builder      |  
                                  | Service           |  
                                  \+---------+---------+  
                                            |  
                                 (Atomic Pointer Swap)  
                                            v  
                                  \+-------------------+  
                                  | Serving Trie Nodes|  
                                  \+-------------------+

#### **1\. Offline Batch Builder (Full Rebuild)**

> 1. **Log Aggregation:** Raw search logs are dumped continuously to HDFS/S3.  
> 2. **Aggregation Job (MapReduce/Spark):** Runs every ![][image11] hours to aggregate prefix frequencies using time-decay functions.  
> 3. **Trie Serialization:** Construct the new Trie in memory and serialize it into immutable binary snapshot files (e.g., using FlatBuffers or Cap'n Proto).  
> 4. **Zero-Downtime Deployment (Atomic Pointer Swap):** Serving instances download the new binary snapshot into memory and atomically swap the active root node pointer:

// Atomic pointer swap in C++ for zero lock overhead  
std::atomic\<TrieNode\*\> active\_trie\_root;

void update\_trie(TrieNode\* new\_root) {  
    TrieNode\* old\_root \= active\_trie\_root.exchange(new\_root);  
    delete\_node\_async(old\_root); // Cleanup old tree memory safely  
}

#### **2\. Real-Time Trending Signal Ingestion**

For breaking news or fast-moving trends (e.g., "Earthquake in California"), waiting hours for a batch job is unacceptable:

> 1. **Apache Flink** aggregates queries over a sliding 10-minute window.  
> 2. High-velocity spikes are identified and pushed directly to a **Redis Real-Time Trending Store**.  
> 3. The Autocomplete Query Service merges the Top\-![][image8] responses from the static Trie with top entries from the Real-Time Trending Store at request time.

## **4\. Key Bottlenecks & Mitigations Summary**

| Challenge | Cause / Bottleneck | Mitigation Strategy |
| :---- | :---- | :---- |
| **High Memory Consumption** | Millions of queries create massive Trie sizes exceeding RAM of single host. | **1\. Trie Sharding:** Partition trie by prefix ranges (a-c, d-f, etc.) across multiple servers. **2\. Node Pruning:** Discard low-frequency phrases below a cutoff threshold (![][image32]). |
| **Hot Key Traffic Bottleneck** | Popular single-letter prefixes (e.g., "a", "s", "t") receive overwhelming QPS. | Cache top 1-character and 2-character prefix results at API Gateway or CDN Edge tier. |
| **Inappropriate / Offensive Suggestions** | Unfiltered logs contain hate speech or explicit terms. | **Trie Filtering Worker:** Run blacklist text filter against the Trie snapshot before swapping pointers. |
| **High Latency Network Overhead** | Sending a TCP/TLS handshake on every keystroke. | Keep-Alive persistent connections, HTTP/2 multiplexing, or WebSocket streams for instant text transport. |

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADkAAAAaCAYAAAANIPQdAAAB40lEQVR4Xu2WzytmURjHHz9jISxY+LGxUDaSZOXHLcZM2NhayN+gLKYZ5ecOCxaUtaws7NTULEZjSvJjIVEUibKQZkwRzfh+PbfXeQ/e+77kvdT51GfxPs9z33ufc+4594g4HA7Hy/kEu2EpzIIVcBz2GDXvniH433JftOlAPLgNL0QvPIc7sN2oGfFz9C+cMXLJoh8ewCO4KfpMuWZBPCyKNlFtJ0A9/AWbYYqVSxZ9oq/rs8mAf+CpRDeRCr/AQZhuxMPgq7ywyTrRWZw1YiVwDjYZsTDhYI/CebgEV2BrVEUAA6JNdvm/O+BPWBCpiB9eswY3EtDjhQF8hj/kfh1y6VzDD5GKAJZFmyyDk/BK9PVNeGG/IsUw34pxI+IgBcJGbuAZXIC1cFq06V6j7i3C15bPWWQnbPhqspC7a44fK4f/4KGEv+EQzuIJnLDi30WfvcaKP2BKtLDFinNWGe+04kFwTXJTWE3Axrsrn8YTfZZvVpz3YZyDEJM9eAmzrXiD6B+sW/EwKBQ93eQZsUz4W/T7HROe/9gIp/0xdkXzbXYiBHhO5fc6TXQJjYlujlVmkYknepTjSLAJFm/Bj36eo8Q81yXz3G05o7xBWPDew6IDfyy6h1RGVTgcDofD4YiLW/wUc0SsRvNpAAAAAElFTkSuQmCC>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABUAAAAYCAYAAAAVibZIAAABKUlEQVR4Xu2TPUoDURSFr5gUSgotBA1C0MIuWKRzC1lByAYS3IBlEEznAgJuIKRK8LcyKVJZRAiIRawjQUirItFzuc/w5swMKQxWc+Ar5pv3Dsyd90SS/FdyLFxWQQ0MQB9cgwN/AWcdHIEOuKR3vzkHjyDjnitgDLbmK7xUwQRcgS+JLt0Fn6DkuRWx0jPPReZdokuPwTfIk++CJ3KhxJVeiJXyvNtgBtbIBxJXqqPR0h3yLef3yQcSV3ovtnmbfNP5Q/KBxJV25Y+lNyyRhtjmPfI6U/ULZ3rLUuxM6uYCeb0Ez+RC0dI7lkhW7AyXPZcGb6DuuVBS4AP0+IWL3ii9ohvu+UTs8G/OV3gpghcwFftE5RWMJLhB7/4pGIIHsR/KM06SZNn5AfNfRCp9SWCMAAAAAElFTkSuQmCC>

[image3]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAD0AAAAZCAYAAACCXybJAAADIklEQVR4Xu2XWahOURiGX2OIzIUMkZQpU0puHKGUa1NCyYUhEhJCUoaS3BgjDrkxJTMX+BVlyJQxQydDGTLdkJn37VvrP2uv9v+fc270x37rqb3e/e191rf/b31rHSBTpkz/gzrFhlMdspzcIBfJCdItDHDqS86RC+Q6mUdqJSJKRI3IYHKEHIvuea0jN0ljN55GXpLW+QigI3lPJrpxC3KPLMlHlIimkzfkOPmB9KTbk29kfODp11PSKwNvE3kQjCV9nE+kaeSXjL4gPemZ5DfpHfk52C8p6SO8Jgfzd01lsGfHRH7JqFDS22ETj9f7YfKLNIRVg2J2JiKAfs5fHflpqh0bf0OFklbpa+JtI3+/87uQge56ayIC6On83ZHvNZs8I5/JLLKAHCAPYZXUhowk+8glchnJilOFLYXN+yQ5A2ugzYOYoiqUtLqxJq4JhNrr/D5kiLvekogAujv/UOR7tSSjYTEVZKzz1QT1IZToelhy4gps9/CaRM4G4w7kA2kVeEVVKOkcqk66zF3XNGlJiSsmF/n3YU2wQeCpkr4H483kKmyJee0gzYJxUSlplXKsQuWtkpPfFYXLu4fz90R+KE1QMdoWQ92GJRRKO4Ri/fqf6sb6ddVj5sC24GpLSWtdxFIienHnyNcfka+vrA+i612JiMpGtibyQzVBeswt2CEn1AZYrA5Lkkp+GXnrfKHnqp24kj4Vm7C9Vi8bEPlaW+G+/IocDcbSCNiz4yI/lA481U16I5JJD4OdAZR8L7IWtqPMcPerlJI+HZtUO9jBZULg1YN93VWBp9J7FIylubCGVGyN+fKuSdJ13bgcVuKh1NgWRl6q9JKv5Hx8w0nrTeduP3m9VCeycGvQXv2RTHZjHVGfk0X5iHSpQSoRdelQd8m1yNsGi/XlW07uoHJeanr68IPcOFWjyBNYI/BrQmX6GMmEVE4rUNlc1OXjNS71h3VhbS36SNp7i2k+7Lyuv6tqqiDDYR/Lz+cFGUqekp/OewcrYVXXYtiyVMPNkSkocdVHsinpl1LVafl4T9fydM//x6Zn9GymTJkyZfrn9Qf/FcoS74n2DQAAAABJRU5ErkJggg==>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEkAAAAZCAYAAAB9/QMrAAADP0lEQVR4Xu2X2atPURTHl3meKXN5NBVK4cVPiH/A9IBI0S3zEEJ5QUlejBHX9CKSEClcIlOmjPEgQ4bMD7wYv9/W3ue3zu7n9zvn3luue8+3PvXb66zzO/usvfZa+4hkypQpU91Qa7AbfACvwUHQK+ahGgDOgYvgJlgI6sU8aqn4khVgJqgPhoE34C3omneTnuAjmOzG7cEDsCLy+A/VGEwCTcILgcaIZofVNPAb7DS2LeCRGVOzwFfQJrDXeDUDs8F1MFdKb4fV4AeYb2zdRIPErUfxP5hZhyMPVU7Ub3xgr7FqDhaAW6IvzGAlEX35ovuMrZWzfXHj7m7MumU10NnXBvZC4lb+Z2JwFokGZ54kD46X35adjI11iS9/yY0Hu/H2yEPV19n3BnavOeA5+Caa3UvAIfBYtA52BmNFG8UVcBX0541OzOCV4Dg4Cc6INox2xqeofHB4EyfQNH65Stoh8W003I23RR6q3s5+JLB7dQDjRH2eggnOzqLPwDEwG0WDQa5JfmGoKeCsGfcAn0BHYysoZorPHAanVGFOK2bHd7DH2HJSuSBRDBR9KgL7Q9GibxeXmcpne20Vra12d+wCbc24oIaCV6KpW53ZQzE774KjoJGx/2279XH2/YHdii9Enw2Bnc9hAKzYQenr69cMN2b2cE4sJ5xjItFxMbgtuu+rK1gHwDHROmXVRXSyNrsoX7jXBXYr3wRCnzuih1KrTaK+DdyYW3AVeO/shPclDhTVQvLBYrtPW7StuEqnJb597fbiAZMBtBotOvGJgd2qpSQP0maJB2mk6BmMweoH1oNfoMxdTyVGlp8Ile1wOXBe4ivE7LxsxtwKT8yY4pGDBbhYjfDbLU2QGrpxueiWs2IhXxrYUonBYZBuSPKzEj833ol2n3sOnqyZOWzNXjwrfQZT3ZhHhhdgWeRRWGzzfHF2Mav7ovO08l3VL1a56Hz8InDhuFBD3LhK4p8xJS9I6UBxhf1+D1lj/KhBol2Krdp312JiF+b3Hv+Lp3ouxCjR4PpnvAQjwDPw09n4oc35M3uXg1PghOizp0stExuALcJcPG4l3zlp42/aeM1/QvGesHlkypQpU6ZMdVR/AKgNvwyij7cjAAAAAElFTkSuQmCC>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFcAAAAZCAYAAABEmrJwAAADxUlEQVR4Xu2YaagOURjHH/sS2XcRSdZsKUm5JVtKPlm6JPLBkoQUpbyUpeQTiShZsyTZKXVf+xpKiZAsZd8SIdvzv8+ZmTNP99z3XO+419X86l/n/OeZ08wzZx2ilJSUlJSKpr02DNVYGdYN1nnWMVZnO8DQm1XEOse6zprPqhKL8GMc6yrrLOsia0T8cjFNWTtI4q6xNrLqxyIEn7b+GnVZA1mHWEfUtYA1rJuseqY+nfWM1SyMIGrHesuaZOqNWbdZi8MIP0azPlH08fqwPrIGhxHysa+wNpN8PNR3sk5ZMcCnLRc1tVFWZrBeso6yvlPJyW3L+saaYHl4ISR3ueWtZ92x6gAfAS/XQPmlgQ+CXmizm2TEBIxl/WK1trwuxhtqeT5tucDoTIwvVHJyZ5E8dE/lZ0keHiDZL1j7w6tCAcm9SIYP3UniZys/Y/wWpr6P9Sa8KqD3/iD5yMC3LRdZbeSDK7kYengYPR8fZP1k1SHp3YjZEouQYQh/pfJdTCSJn6z8ucYfbur3WQ+jyyEfSOZV4NuWizPayAdXcjFl4GFaKR+9B35HVn9T1kMw6D3blO9iAUm8PQWBYPRMNXVMNXejyyGvWI9N2bctF1iUE8OV3CKSh2mp/D3G70WyQKC8IRZB1NX4B5TvYglJ/HjlY22AP8fUMWL0/A4wNb0zZd+2XJRLcrOUO7kFppxvcjOUOyGY31HOldwM5W6rNBJPLqYAjWta2Gv8TuSeFroZH/tRH1xDeabxp5m6a1rAzuepKfu2tYhkn6yFLZv2oO1yW9lAco9rkyRheJgOyseCBh8LGhKP8tZYRLSgrVK+CyQC8VOUHyxCwQEAiX0UXQ7BgnbJlH3bcpF4zz2hTZK9Kh6mn/KxV7SH5nPWYasOsOfEvXpougj2qjjZ2WA/DT+YmrBXRc+yqUESE0xNvm25SDy5J7VJslHHAaPQ8vAir1krLA/7y3tWHcxjfWY1tLwxJPO0C+ydNykPp8cLVj04RLSxvL7GG2Z5Pm25SCy51VlfWaf1BQOOv/ivECRpIckJrVEYIXvd9xTtK3E0fkIypwWg9yMBWHRqW74NjqwY3j1MHUdznBAHhRFEVSk6/qKM58dirDuHT1su8k7uKNYDkpfFS0MY3tik24nD6WcZ6xbJTxC8iJ6DAXpPluTF8TH06ag5yeYfQ7q03otpBD9+LpP0siHxy8U0Ye0i+ecBrSP5T6Lxaask8k5uRbGaZJv2L1Npk4udxp/8iixPBmijMjCStVSbKcmwllVLmykpKSn/Mb8BEVsZI4njfrwAAAAASUVORK5CYII=>

[image6]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAC4AAAAaCAYAAADIUm6MAAAChklEQVR4Xu2XS+hNURTGP4+8QyhRBlKYUTIxkddIUlJGDJBiYKAQYiQpKRlRRFFSyoBIlAjJY+AxEMkjj0KSvPL+vtbZWtZ/n3P+97o3k/urb/Ktfc5ZZ9+11zoX6NDhvzCQOk2NioEGWE+tiGa7OUktiWaD9KIuUjNjoF0so85Fs0kmUq+owTFQxwhqE3WBOgvbgRvUZqqPW5eQ95SaFwMFSuAW9ZL6RX2l7lN3qOFunecMtTGaVayCPWAN1c/5Y6jb1E1qiPPFAtg1PYMf2QBLfHUMZFhIvYaVTiU9qD3UB2pqiCWmwR68K/iHqWPBy6Fd1PXjYiDDSNjaslz+sBW2cGkMOHpT36nHwX9ArQ1eROX0kXoYAxU8Qc19p1A/qLuwnS9DpaOXUwKJQdRPar7zcsyAXbs3BirQ+ToYTc9RdK/2Uqn4XRtbeNOdl2MbbJ1qt7uo/E5EM6Edfge76YQQi2yHrdNZSEwuvEnOy3Ed9qsOi4EK9lFXopnoD3uwlGt1iQHUG1grG+98JVyXuFqekr4WAwVzkC81JX41mp73sDrtGwOOHbAE1wVfbbKuVBbB1qhccqiW1UUiKhV1olIOwW48KwYKNMb1YjtjAPZL6NrcjiX2w9bMjgFYzR+PZoFeSLmVMhrW4u7BDltCu7Cbeovqb5BHKG9bGkrPqc/4e6CpRNUMPlFzne9RO9QgrER1qB1V8pdh4/48LKGhbl2OA+g6gNQmdSCfwXb7G2zsSxr3XwpfEzc3HdMAUidrG6rhF6gf+Y2gEmr1PbugiapyKfvIagYdyi3RbAfLYYepFeizVrtdV6It4wi1OJoNonq/hNb+erWoU5zCv/91WxnNDh2a5DesE4WbFjlfWgAAAABJRU5ErkJggg==>

[image7]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAA4AAAAaCAYAAACHD21cAAAAtklEQVR4XmNgGAW0B45AfBmIPwHxfyh9HYg3ISvCB3YyQDTqoUvgA6xA/AWIH6NLEAI2DBDb5qJLEAKNDBCNkegShMAxIP4HxGLoEvgAPxD/AeLz6BKEQCADxJld6BJQUAHEMuiCIDCdAaLRDV0CCPiA+DC6IAzcBeKfQMyFLgEEU4A4H10QBNQZILYdQBOXAOJpQPwDiIWQJWyB+AIQv2eAaATRIP4lIL4PxH+h4qthGkbB8AEALIIlVs8MCuUAAAAASUVORK5CYII=>

[image8]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABMAAAAaCAYAAABVX2cEAAABDUlEQVR4XmNgGAXDFzgA8XUg/gLE/4H4AxDfBGIfJDWtUDkQ/grEs5HksIIdDBDFRugSQGALxMeB2AWIGdHkMAArEH8G4lcMqIqZgLgaiJuAmAVJHC+wYYC4aimSmAwQLwdiZyQxokAjA8SwOCg/EIiPArEoXAUJ4BgDxDAlIJ4MxD8ZIN7mR1ZEDABp+APE74B4IxCbAfEMBojhpUjqiAIgL4E0gmKTFyqmBsT/gPgRAwkBDwLTGSCGuaGJg1wJEo9CE8cL7gLxDyDmRBO3Y4AYdh5NHCfQZIBo2IcuAQW3GCDy3ugSyMCBAZKFPjFAFINi7ioQu0Pl2aDyoHADyYNiF+RCZqj8KBgFdAUA1cE4UD3uB1gAAAAASUVORK5CYII=>

[image9]: <data:image/png;base64,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>

[image10]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABEAAAAZCAYAAADXPsWXAAAAw0lEQVR4XmNgGAWDCjACMRO64Fkg/grE/4H4DxA/AGI7ZAVAsIEBIg/C74A4FVUaAoIZIAoWoksggZNAHIkuiAwMGCCG7EWXgIIQIO5EF0QH/AwQQ+6gSwCBIBDvBGI2dAlsAOTXnwyYgTadAeJSosAZBohrpJDEnIG4AolPEKxmgBhiCeVzAfESIGaGqyACpDNADCkHYjMgTkGVJg64MkAMmQ/E3WhyRAMlBoghz4FYAk2OaADyOyjl+qNLjIJRQCkAAEjqIahLnhVtAAAAAElFTkSuQmCC>

[image11]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABMAAAAaCAYAAABVX2cEAAABDElEQVR4XmNgGAXDFzgD8S0gfg/E/4H4IKo0GJwF4n8MEPlvQDwbVRoTbAHiewwQDZZociCQDcTLgJgJXQIdsALxGSCOYIAYthZVGgymMEB8QRDYAPFkIGYG4vtA/BeIVVBUQCxjRxPDChqB2A/KzmWAuG4aQppBCoi3I/HxggNAzAtlcwHxGwZIQItAxeKBuAjKxgv4GCCGIYMmBojr6qD85UCsi5DGDfyBuB5NTBSIvwPxKyDmBuLLqNK4ASiWrNEFgWA6A8R1c4B4EZocTnAOiFnQBRkgsQmKVZCBMWhyWIEdEJ9GF0QCoPQGMkwCXQIZuAHxAwZEFnkCxPbICqDAnAGSlUbBKBhQAADIFjDhxd8YOAAAAABJRU5ErkJggg==>

[image12]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAApCAYAAACIn3XTAAADJUlEQVR4Xu3cW8ilUxgH8OVYLlCDybnMhUPKhRpTQpMbuXMlOUZKDuWKJk3Nd+fSNFO4IReIkuRCkmPGkCShHCM53BA1ockhnqd3vb4169t7C3vPfH1+v/q31nrW3vX1XT2t/a63FAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKA6qy9M8XhfAABg8Y6JfNAXpzg5ckJfBACYtz8iX0U+ifwe+TDybeS59kNrSJ6e7Yg8G3kxcvW+2+XnyHFd7b0y/J/2RJ7u9r6PnN/VAADmZnsz3xa5oVnf0szXitcjx3a1uyKXNevbmvnosMiXfbG6ogyNHADAQrzSzHdFTmnWFzbzteCQyN6+GDZHHqrzkyIb/9pZdkHkgb5YnVaG0zcAgIVbTU3HuWW+z4Zls/Z15Jx+owwnbGMzdn3koGZvtDuyvi82vusLAACL8Gtf+BvZwNxX59dFLmn2Jpn0U+M0j0Ru7Iv/waVlckN6Xhnqh9b17c1eq//uljJcOBh92swBABbi+DKcIv0T2azd3xfn5OEyu2F7M/LWjPTyxK5vutIbkV+a9TVl8glb/91Xu7UTNgBg4fJEa3NXu7KOeWs0jU3KZ2VobJbKcsOWJ1PZZKWx0cqbpumdOuZN1LQp8lHk1jJcdNgZObHu5d+RXiqzG7Z/4+LIE836+bLyebVTJ9TOiLzcrO+NrGvWnmEDABZqKfJ+5LfIN5G7a/3IyIY6f6aOL9QxG5Z8YexSWW7Ybi7LDdvZdcxXZqTx5G5s2I4oQ7OUJ1nZzOVrMpYiR5XhlRrpqTL/hi09WoaLFtl8XtXtjdqfbvPv+6Hm3cjnZWVzlrdEf+xqAAD7xbV1/KKO2WSN68sjd0QejGwt+zZsZ9Zx/PxrdRwbto/reE/kzjK8Dy0dHnmyzrOhuqnO97efysr3sM2S72G7qC8CABwIYwM2ycFlODHL95Xljcwc0/gwf79ezY6OvN0Xp8iLB/kzKgDAqpDPlf1fnN4XpnisLwAAHCh5apbyJA0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACY4U/HPnmixzr0jwAAAABJRU5ErkJggg==>

[image13]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABUAAAAYCAYAAAAVibZIAAAAY0lEQVR4XmNgGAWjYPiCJHQBaoDtQCyGLkgpCATiDnRBaoCVQOyELogMlgHxETLwTSD+B8TNDFQCqgwQg43RJcgF7EB8FIgV0MQpArlAnIEuSCk4AMSc6IKUAhN0gVEwCiAAACBLE8KU5AMmAAAAAElFTkSuQmCC>

[image14]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACQAAAAaCAYAAADfcP5FAAACJUlEQVR4Xu2WP0hVYRjG34oig4ggJWgrooSgSYKkwYggmoIgh6ClwUFokihFlwqyUqEhIlT6A1HQItTg4NBQkEJDRS2i0mChaNCi/fV5eM/R7zyc890r3EW8P/jBve/zce93vr/HrMo6pA+e1mIOjfAR3KBBJWmDA1qMcAt2arFS1MNvcLsGEbbACfPRWjU18CF8CT/DA9nYnsE7Ugtpgse0CK7AYS2Ww134CV6Df83/IKUO/jEfpTw2wTl4XwNQC//BwxrE4Oj8NF+wHGZ2IOQinJVaCKfkP2zWIOGL+form+PmP3hGg4QH5lNZRIf5KOzSICFdCiU5BT/AGfMOfUy+nwgbgXewV2rkhfnT/zIfYX5+nWnhtMNJLcbggp3WYsAU7NJiwja4AG9rENBq3uGy4ZO90mLAD3hJiwknzUc3dlieN2/D9VkSLmjuqusaBMxbcYduwt8WP5/SDm3VII8j5o3PahAwbsVTNgbfalHglC1qsYgW8w7t0yCgaFHvsOzo7oaPV+JluKi/arEIHmZcI7FLcNDyt+1+84c5BzfDp/BQpoXDbT+kxSJGrfTRfsH8aMjjHnwPn8MGyVK4aa5qMQ+uem7ZyxoIeyx+dcRIr46DGoRwiHlN8InYeG82zuWJxS/XIni5jmhR4SFIuXM47+XA0flu8e2tpK8fRzVQbsA35vO+U7IY3JH9WozAF7RuLVaaHoufyil8A+ARsFGDKmuaJWmnaWTU3AmiAAAAAElFTkSuQmCC>

[image15]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAcAAAAcCAYAAACtQ6WLAAAAhElEQVR4XmNgGMpABYij0AVhAK/kJiC+iS4IAmxA/AWIZ6BLgIANEP8H4mBkwXIgvgHEH4D4L5QNwgpIahgOAfEZZAEY4AbiX0DcjS4BAp4MEPtANAboYYDo5EGXAIGzQHwUymYE4q1AzAqTfArE06HsKiCOh0mAQCIQ3wLiVegSIx4AAK6sF9s/dRChAAAAAElFTkSuQmCC>

[image16]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAZCAYAAAA4/K6pAAAA5ElEQVR4XmNgGAWDD6gAcRS6IClgExDfRBckFrAB8RcgnoEuQSywAeL/QByMLkEIlAPxDSD+AMR/oWwQVkBSQxQ4BMRn0AWJBdxA/AuIu9ElgKAYiKcC8RQgjkOTg4MeBogBPGjifUA8AYk/nwHiZQxwFoiPQtmMQLwViFmhdCtMERBMB+K5SHw4eMoAkQSBKiCOh7L3AHELlA0CIK+sRuLDQSIQ3wLiVQwIzSCwFojbkfggS+Yg8QmCLiCejMRfAsSVSHyCwBSIj0DZoLC5BMRqCGniQAkQzwTiWUCchCY3CqgBAJHaJ4Tm3EwNAAAAAElFTkSuQmCC>

[image17]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAA4AAAAaCAYAAACHD21cAAAA3ElEQVR4Xu3QsY4BURSA4SPZKLawFdW2WyLRUIhks6VO7Q0UXoAt2QfYhGjFC0isRKJHQSQSGj21SlaW/5or7pylVYg/+Yo5Z+4wI/Lodn2gixEG6CCKNiLOfb7KWCDmzJLYYOrMfKWxR1wvqIUvPTxVxx+e9YK+kdHDU2ZpfrGHd/E/4AUB59rXG9biHTZ+MUTWvelaIeTRwFy8B+zk8nsfu/aZq+IdLuqFKYy+HtpS4h3M6YXJ/LWJHtoqWCKoF6YmtijJ+Us+oYAVEnb2rx+84hNjzKyanT+60w5g7iek98V0vgAAAABJRU5ErkJggg==>

[image18]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAA3CAYAAACxQxY4AAAEIUlEQVR4Xu3dW6i0UxgH8OV8FnJKDt8FUSSKFFJcKC5coEhKLiT1uVG4kChnUbgRKUKSC6ecyYVTLpzPEilFDiXJmVjP977TfufZM3vPzJ5hm/371b9517P2zOzdvlmt9b5rlQIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAf2+jXFiB3WoOyUUAgHHdWfNjzdc139R82+a7mu9rfqj5pebXlHPizf9zj+ZCdVEurNDNuQAAMIm/a36q2T93DPFaad4zD87vXN9ec2h7fXLN852+UbyTC60DcwEAYFx7lGYANs4gbLOafXJxGUfVvJmLQ7yQCzPyZ2mWLsPL7eu6mp/L4Bm4YS6o+bw0783uzwUAgEn0Bmwn5o4l7JcLy/ik5uhcHOKAmu1zcQZ+qzm3vX6sU49l4C067VFcngut53IBAJhPl9Yc3F4fUfN2p28atqx5tzSDtmnceP9+zZU1x3Zq53WuwyY1t6VaV9xLFz8zKx/UHFbzR9vuDqyuaV8vbF+f7nUMsW2bQYO8p3IBAJhPebny2tSehoNK8z29Qcqktqq5qWbzTm3f0nx+VyyRnp5qXfG7HJ6LU7JLzant9cftawzgek4qzROed7ftVzt9g/RmDrcp/ffFBQ8eAMAaEYOXmK3aum0PmgV7qOatJTKKuG8rviuWLydxQmlmxt4rzYxdz/Wd6/BRze/t6zDP1tyVi8uIp1cfKM17xxX3oZ2dar3B6zgPIMTDC9u11/F/2rTTBwDMsbifKwYCH5bmRvlZ+qs0g7bTcseIBg3CHk7t48viWcMYcHbdUfNKqoVYGj4jF0uzRcm60sxyXdLfNbI8C7gS8TDDFbkIAMynXVM7D3Sm7erSfMdLuWNEMeDL8mDsurJw71jPcakdA7ZBS5ExE5Y/b+fSfF48kXlfzVn93QAAs3NmWbwVxqepPW1Hlmbj3EkNGlDmJdEY1F1Vs3vbjnvVHlno3iCWNe9JtWHiqdL8vYOWjQEApu6Jmj1r3ijNfWG39ndP3U4163NxTM/kQrV36V9ujL8jBqK9hwp2rLlhoXuDGIDF4HFUe5Vma44Hy+AlUwCAubDSDWvjydCLc7GVt/XIetuW9HxZs3GqAQCsabH3WGzJMap8sPlXNZelWtdnpdnKY5CYgbux044lzh06bQCANS8Ofh/1LNE4lureXBzRKbkwxHKzcQAAa0rs9n9MLi7h9bL4Bn8AAGYk9neLwde4ia0zAAD4F8TJAHHWZTzZGWdp5sTWGtEXP/NkaZ5afbyMfog7AAAAAAAAAAAATCqf7wkAwCpyS1l8vicAAKtIbKT7RS4CALB6xFFS+XxPAABWkRdL//meAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMB8+wdFUKn4oBk8YgAAAABJRU5ErkJggg==>

[image19]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAwAAAAaCAYAAACD+r1hAAAAxklEQVR4XmNgGH5gNhC/AeJWdAl8YA0Q/wdiTXQJXMCNAaKhEV0CF2AB4tdAfANdAh+YwQCxRR9dAhdwYIBoaEMTxwmYgPgZEN9Fl8AF2ID4DAPEFlM0OQzACsQbgHgmA0RDL6o0KgCF0FogngPl3wbix0DMCFeBBECKVwHxMQaIk0AAFOMgW2xgimCAGYhXAPFTIJZAEtdlgGiYgiQGBguB+AcQm6FLAMFVIH7BADEUDDihAjEwATSQDMT/gDgYXWIUDBwAAJ9PIdzPlIZYAAAAAElFTkSuQmCC>

[image20]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAA2CAYAAAB6H8WdAAADXElEQVR4Xu3d38tlUxgH8DUGE/k1uRDlgmJQUmrIjxruNKiJC4o7JKVGaeJmZpgZUdK4FZfkR5QZcUOJciehlPJbZDTulCQTz2qv7X0s57zNvIfO68znU9/Ws551/oDV2vusXQoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADA0er+yKN9cxnbUr0m8nXkncim1lsbeXf8AQAAs9sT+b5vTnFh5ECa74qsi7wXOZT6F0ROSXMAAGb0eN+Y4vcybNqqayN/pLXPIhvS/GCqAQCY0WNtfC7yQ+SqyL7It2V47Dl6PdXV5jYeH/k5cnJa+ybVAADMaNywnV2G07YP2vy6yA2trvamOrut/P20rXqzmwMAMINxw1ZtidzY6tPL8J7aaGuqs/o49Kyu90w3BwBgBnnDVk/U6slatT6yO63tTPWobtZG56X65VQDADCj/KeDesKWN2z1X6Sj/pHoGZHz0/zUVHskCgAstKcjj/TN/8hXZfj3509lOBX7peXB1qtro/zPz7qpq++t5WT9HABg4dQNz8N9c86ejTzRN6fY0TcAABZNPc36tG/OWb2D7ce+OUG9OPe0vgkAsGiuKav3seL1fSN5IHJP3wQAWET1Mtr3Ixv7BQAAVodXI0+Vw39n7HD0fxKYZwAA/reOjbxUhhO2atrmpp6+TUu+XgMAgH/Zr5HL0vyTyNo0BwBgjk6I3N717ojc3PUAAFhgv0W+LMPJXX3cWsd6fUi+IBcAgDl6I9X5/biPUw0AwJxclOoTI5+n+dupBgBgFajXhdzUN5dRP/R+Zt9szo1c3jcBAJjNR5H1af5dqie5JXJnq7dEvoic0+Y7I4da/VYbT4rsj+xtcwAAjsCt5Z/3u23t5pOMG7ZJ3zg90M2f7+YAAByBeppW73vL7o2sa/Ulkbtbdvz1i6UN26TTuHHDNq690MZNbaybvA2tBgBgGR+Wpc9D1XpUN2yjK8vwpYX6EffXUn8lG7YnIw9FXolc3XoAAKzAfamuG6t6L9vFke2RPa1/VxsnbdgOtnFce7GNV5ThXbnNkUtbDwCAFVhThu+Y1hzTrVVj/7h+oSz1xk9o1d8CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABHoz8BvASgCskg9JMAAAAASUVORK5CYII=>

[image21]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAKMAAAAaCAYAAADbqew9AAAGQ0lEQVR4Xu2ad4hkRRCHy7zmnNOZI3oiYgD1lFMR/cOcUFjFjBkRA+qJa8DDnAMu5oDhzNlbxXDmjAH1VIx4IoI512d1zdT2vtmd2TnXdegPfuy8ev1Sv+rqqn4rUigUCoVCoVAoFEaaeVS9qm9UX6huVS3Xr8VA5lZ9rlot3xHYUvVX0qPZvkJhADOo+lQHqGZUbaT6UvWVaol6swFMFHOyNfMdgZnEzoGDd7Qz7irWGT+o3lW9qfou2b5WvaV6X/WL6lfVxnZYIWMr1eTMtrdYP16V2Z2VVD/J0M7o8G462hkfVJ2qmi3YeGA6aJVgW1b1m2qRYCvUOUX1u+rIYFtSrB+JaFVMUl0rzTvj69LBzriQ6unM1iU2Wj/J7PBabijUwAlxquuCjXwQGzNNDpH0UtXR0rwzviIj44xz5IaR4GDVHpltvFRPLTjpI5mtUGdW1e6qhYONvJG+zAf8zMlGMGjFGV8Uc8bNVXepXk22sbGRWP56UNr3jOol1X5hfyyIpiTbXMGGuEe4R/Wx6kexlO5Z1VTVhmn/9qr7VPeqnlQ9pNou7WuJ5cU6MXKm2M1w4Qg3R47TCeAwL4u9zGY1jgNb5Eqxvtwlsx8m9em8VWek8r5IrKjB6V5QPRcbKeeJtZ03bVP8UA/0pG2O5d1TE7gzwvxiThWdkdWAq5PtYakPMK6xgmqa2AwApHoMsp3Sdtswiv4UG7XTAx56fdXs+Y4KZhFb4lgv3/E/ZA2xHPuazL6AWHThWaFVZyRCxWmUqf6PsE2Byfny6LS/2HtdK9jekP7OCDhZdEbYN9n2FBsAu6kWEwtY36vG1FradbYO28NmQbEbJmrkHC9WcXdn9qE4WayzVgy2k1RXiHVuhIh1o+rTtI0DMyWQOjiriq3lERF2DPbRBM7Ci2YqdadziGrbhO1WnZFgEblQ7HiWk+CStL1yrYWxSbJ7dARy0FaccZ1gA94FRRsrLX1ihfAysUE7EF656Fn5jsQkad0ZgenAnXEL1R2qxVWXiY20CBHFnZEOniA2HThMA4zuQ8XONRq5QSzXylMgno1pMNKqM+bOc77Y8Uy9wABgO19s3yDZY6RmQOfnG8wZ4+qKQ874nth+xIJ/jL7DBufghCS4Vdwpw3NGFn/dGVkU5jqNYLS5M1bBMglTRDsQgZ8Xe7nNatN/jhyaI8Ryq7hU5s97lNjLoj9cTHP0+TSxpZvBqIpkuTNenLZz52bgYqcmcMg16YeIR9oqZ4yzG+Ccq6ffS4sVTawc8OWpbT5Q/SyN87vbVeeoTlQ9oDo27Dtb7EGYfpmK4sO4M66rekpsEZ1qPbZxojNSAb4t9YqftTxyJh52B7HoykjvUd0i03GKGCbjVE9I/5yuSyxHbAR9VeU8VVTleO6M3pdU2mzvXGthUDRhj/k495VP+3eLtYtRvZEzdquuz2ykYKxdtwWVMhfsy+yR21Q3pd+0/zbsY0QyFcDj0r8zYmQ8UAY+QCSPjERjOsOJ55os9bwRhyXf/K9gIJCOTBX7UoLeEbvfwSKFz0bNTG0MTKJjxCPhnMHWK9bOi9ClxALNubUWBu0+DNukEUQ2zjdW6g5ORMe2dtp2usXqiGgnRTkmbDcNkYWbZumCTuOCJKN8AsQ+ptbSwBkPSb9ZLuDzoLOoWLFyhtgIZiQ67TgjEa/KGecTu98LxPJKInO+NjqSMP1xP1U6PbRzWJPEcSkAaMPAbhRBqZA/k/r56J/xYo7kxzP9e5+Tax8uVojyoYK/9HsO758oRp7ZK/buqBf8OhPEfIOilm3eN/fh7CU2GHhHrDU+JvYe8qLtX4HCwx+KvI2lC6AK5yb5qgCMDjrDp6vojOQV7oyXi3Um4qEhd8abpb8z8o8H0RkZzZ0OEcpfMAUfv7F1pW0gZ8wLpuHAO/P8c1RDNe3OyKjCiWAzsZHpMEJI5HvSNtMX0zpEZ6wC54qjL4+M7oxwv+q49JuXckL6Xehw9hGLWFNU24pFPyIT0Y2RSi7JsgCfGFmTJJFn8ZOwT3gnb2J9jeM/EitGcoi2pAIUUaeJXZNv5JyLqs3PhYOSn5IT8Zt/Npgog/9PYKGDYFoAnyY8lA+VH/h+jvdPWI0g14nnRbTHjoa6VqFQKBQKhUKhUOhQ/gbMmZ+Y4aKjHwAAAABJRU5ErkJggg==>

[image22]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACYAAAAZCAYAAABdEVzWAAACpElEQVR4Xu2WWaiNURiGX2SKC0PGDMdYLoQUCdnIDSGUDOWKUnIhlAtJRFFcCskUCiFCSGyEIkNEwsWJZMiFJEmm9/Wttf+1vz2ccy7O3X7rqf9719r/+ta/1vrWBmqqqarmkcvkKOnr2qJak0OkjW9INYisIcNIO9KPrCSH005UK7KRPCK3yUUyNO1A5chH0ik8f4G9q2vWBaNInmxNvLKaSv46vpNpaSdqB3lMOoZ4OXlPuhV6AOfI7iTWl1tBTsImcomcIa9gH6GqcuQzqScvyQEyJGmX+pCfZGHitYAltiXx6snmJN5JxiaxdJ5McV5ZTSQHvemkWetLDnd+njxP4ndkUxL7xBaQ/UlcVRPQcGL7YIn1d/5Z8oe0D/EVsitr/r98cX91Jk9Il6y5usbD9sYecpU8I6uLegAXYIn1cr72jvyBIZ5O3sCSyJHjwZc0uUVJ3KDGkQ+wUylp8E+wExh1HZZAz8STNLD8EYmn5bpBTpHuwZsE+3pNUgdkM45SjfmBLJE8Gp+YV1vygNSFWAfpGGx1ZgSv0dLJ0oDx01dayhPBH+z8VDoMq8KzauFTMh9WLu6QHqGtRLdgM9KPojbABlThlbT/FA8o9DBp88uPm99L20PFOL57JmwlWoZ4DlkbnoukH/wiX1H88u2wAReHWMVU8ehCD5MGfeG8KNW5a2Rk4q2H7d8o1UsdirJ6SMY4TxX6G7Kj3hs2gZiopPtOhbnS1bKMbHOeljVNTFdaxcRmw6qx7jdJl/BvsrTQw6QrSfdk7LcOVvlVGrx0Gu+hdIm1t7SUcWnnosJSRumIq/i9hQ2u5Lz0Ms1Ym/c+bDJ+z0UdIZO9Cdvwr8mS8HwXpSe92aQraK83E9WR0+QmmVXc1LzSfyzVrppqqqmp+gf0WYgXU6mA4AAAAABJRU5ErkJggg==>

[image23]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACkAAAAaCAYAAAAqjnX1AAACFElEQVR4Xu2WXWiOYRjHL59F2g4wsxxp8lGonczBUnKgZUXKmSNHQj5KKZnVWptkpdCQM9NqlCKUUM5wQIuyk5UDirRaSfma+f277if37tqe7N16lOdXv97nuq/n3Xs9933d9zOzkpKS/4uteB+f41O8i+vxNtZE9xVGKw7ihmisET/jQDRWGE04hhvTBFzH0+lgEVzCX7gwTcAF3JwOFoEK0Uw+wC02vthqnBXFhbEKP5oXKn/gM9we3zQDrDTv+wVpYiKqcA9ewTfmxf608X26E3twCNvxYZSbCm04ivVpImWio6XLvNDDIdayv8W5eBF34MGQq4RPllPkUnyUDgY2mRe5K8SrzY+o6eaD5RSp5X2ZDgY6zZd1Pi7CG/gFr5o/gJZah744isN4Fo/jHfOlzOjG8+atpE2q1cjILfIafsOT9mdH6w8cMP9yQxgTa/BdFKtX41iF9YZr/ehIlFN76MHEY9wd5XKLvIcr8BS+wNdBbQ6Nx6RFrk3iW+YPJ+rwe5RbZj6z6vNXeCjK5Rb5N6RFpUXfxH3hutb8GBOL8T1uC7HeYNqM2crNaJFprJnMilxufnwJvRzUrxnaqEewI8Ta3TqnK0Yzo5n6at7466L4GO41L1j/ObWYz5ZOhss4D/vwHO7HE/gEm/GMeVv04xKrkNk4J4m1wYQ+s2u9PlVUdq+uJyPL6/v/xKu3pGQyfgOKlmrBo+R1ewAAAABJRU5ErkJggg==>

[image24]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAApCAYAAACIn3XTAAAEv0lEQVR4Xu3cR4hsVRDG8TLntDErmEARURDFzDMsRBSMD1wILhQVMYCuxISYFmLCHDA9E2IWQTChiAFRRAU3yjOBAVRUxIjWxzlFn1vTc5/D6+meof8/KM495/b0VN8ZmKLuuWMGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACwQBzq8Y7HWx67eTzTPT1Rq3m8ZiW3O21h5QYAADAWB3js3swf9Li6mU/aN2l+eJpLm3/YMC+MiXLZIa1NKpfs4DRfxePotAYAABag2zzWbeY3eRzUzCft7TRfO81lO4/tm/n6Hi8183FSLjnnSeWSvZDmN3qcn9YAAMACtJPHvx5/2cxCYy5UMK2TF0dAeSm/Xz12Sedae3q857Gmx9J0rqXi6TqPH+tc7633vdLjkHjRCEQuz+UTjZut3I5WDqJreIaVLuI/Hpt5bFHPjYp+xks8Lk7rWeSljmHkJcprnHSLHgCAqbZpml/lcU49Xm6loJjLLbMd88JKWN1jk2auzloUNrPR13ySF4fQ+xxTj5e1J0Yocmk/wzDqbt5Qjx9q1u+r4ynN2qhc7rFXXkxWlNe4nJkXAACYNvlW3T4ex9bj/1P4ZH0F27s9MczxHpektb7uzqpWCoslHht0T83wi8daVrqLURDtPDg9EpHLK2k90+fcvx5/XUd9lvjZjLpgU6fsMSsPcfQZlpfk35n5dnpeAABg2vzhcWE9Viej3eD/VR1jQ/95Hp/V4z3qqALvZY8T6ryvYJurLz1+sLIxfiOPuz027ryi67LmWN2zvqdJl1vpgN1jg9x1LNqDpidT9f239Pi+rt9h5XN/VOd31XGY69O8L5eTrFy3k23QQdRt1NhXGAXbaVZuY6rrKdEZ/KmO+tnoWn1ns3f1jrPuHsA3PbZu5q3ISyIvFcKR1+t11PfVa9vrJK96HGila6vcVfytZ+Xay8dWbhnHe8fnuaWOOi8UbACAqac/1ioCVITcWuchCrbYN6ZbperMyH51VAfsQ4+z63yUBdu9Htt4fGBlP9gFnbNdw27bnpgXGo97vGGlkFAn8XkbdOWOqKMKCRUUP3tcaqVgvMbj/nr+NyuFXaZcrkhrfbmom/a+lYc9jvJ40brdvijY1Bl71uOJOo9bhX/WMQqfT+s4TN5Pt6vHw2ktRF5P2SCvJ5vz0WlTgfWoda+T6PVymMfvVgrqIz2+qOu6fvvazEJP30t7DFWsCwUbAAA9hhVsj9Rj/SuQ+BcR+sN9bj3WLcbFTv+CQ4XZVnX+bR03t9IlilvFUbzOt1OtdAO1+f4iKwWURCHzdx0f8LjWBrcx51sUZJ9becijvU4SBZ0KUXUm9UCHOqXqAIo6mOr2RVf39jqeVUd1DlWksocNAIBZqLsSo4oFhW63iY61Hq8Ja9Rz8brFSoWpOmfalK+iYpLiWudOXlxnXXPR+HRd29Zj77o+n6JgWxnt75SONWazrQMAgCkWe+G0Vyv2US0Gy5rjcRRsK3qYAgAAABMUHb/cZQUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALEL/AeJsus/hGSsJAAAAAElFTkSuQmCC>

[image25]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACUAAAAaCAYAAAAwspV7AAABvklEQVR4Xu2UTUhVURDH/36AgproIjeCBGLQ0oUgCIILF7pXCFeVkkRpLQQl4S1U/AAVQcGgDEwkUoRANNSV6UKEMF0I4spatBCXguLHf5i5vnkgru5FiPuDH8yccx5vmDvnADExMTEx/xf19Ac9sDiglh7TB5av0rXkdnSU0EWaQX/RBbc3Tf+5fINe0ky3FglvaDW0OPnDt27vD511+RN65PLI6abn9KHlZfSKvrg5ATyiMy6PnD264vJmaFGlbq2VNrg8UmRGpIAetzZGT10uLNNsiwuhn3aIfqfD9IPttdBJOo7kOKTRLjoA/c07W7+TQ/rF4hxo52TGgs/5HNqpgCn62uI5aGeLofP5OzhE9ulj6NmgaEHGoMnlt1JBN+kStCM10Nu3C+2EzJxnizZa/JH2WTwKLSphztMquk2f2RmhA/oMhcoIfW/xOrRDwfo3iz1S6EuXd9KfLg+FBLSAfqR2oJL+pQWW19Fy6Dx9Cg5BC3/l8lBooxf0jJ7QrzTX9p5CR0CGPxj0dNoLvQAT0C7L8IdGFnRGiizPhw6xzMm9kUd3kHwehHbcc1GC3M7P0LdN3rRBpBYZEznX1E5UE2P0u9gAAAAASUVORK5CYII=>

[image26]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACoAAAAaCAYAAADBuc72AAACCklEQVR4Xu2VS4iOYRTH/+6iWJGSWyG3XEYsbCYWUhZ2kpKFSymJjQVDLjONsMHCsGCBmXJPuYWkkMXUKJoNNi5FsqBE5PI7nfPOd5qa3Tcz3+L916/vnOc83/ed57znOa9UqlSpUqVK1aJWwl14FXah5fAFRoV/Hx5Uwn2rSXATBkEHXEuxc/Ap+U/gLwyHmbAoxXpd26BenrAlsSPF3kNb8mfBOxgDrRHvc+2B3zA2/OnwDzZ27ZCmwIWwZ6ufEn0J95K/SZ7o1LS2BVaHPUP9kOhgeVKNae04/Ei+6Y68P0050RER2weXYHOsj4en0Anb4QC0w8SID4BjcASuwyF4FrEe9QbOhz1SXmHr2aIVNsgrWignOhquxqcl/RXGRWyhvAjTwrf/sKRN6+FK2Fvll7c4RI9aLD/9bXl1lsm/+AJuyHs4q/ujnw9H4SB8g7mxPg8+F5vQadgV9mE4GfY6+f9XXTlRmxpvVanGB6iDYTAHPsa6qQV2h71KPptNdsC9YVdVdustIdN+VR6h9fB3WBtYRXOip6Ah7KVwEZrlvzG02FQtWf9dhp/QJK/kQ9gpn8Mn4BYskB/gl/wxr4HX8BxWyNvlj3ws2uEey18kVdNA+ZvMNCQHusludd5n08XWDLPtLbgkfKumXVg7YM3pkSrTwGQVrslEJ8MZ+fy01jgLE/KGUr2l/w/AZkD14hxbAAAAAElFTkSuQmCC>

[image27]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFwAAAAZCAYAAAC8ekmHAAAEhUlEQVR4Xu2YCahVVRSGV5Y2ORRmg2Y908KwiAoiy1TIBhCLCodKECOhjIioIIjqoRYhFoEiRUEZGQ2EKJYWpQ8jtUELo2hOS8ommudxfa69z113vXu95xnIS84HP9z9n33PvWftvdfa+4hUVFRUVPzfGaq6XnWsah/VEaqrVQ/5TsqeqnbVa6oXVU+rjvEddpK2aDgmq15RvaBapzq3/vJ2DlI9LNbvVdW9qj51PboZZ6r+CfpZdZbvpNypel3VO7WvUH2mGlD0KE9P1XDVXapvw7XMeaqfpDaoJ6p+UI0petgkeFl1v2qP1F6ses716XaMVX2l2qx6V/WA6mh3HQ5X/a662Hk8IAG/zXllOF71tdiM/Vj1Y/3lgrfEZqvnUbHVlZkkNkEGOo+BxIsTpttwhurBaAauEnsIguXpEAvMzrJSGgd8hNjvkdo87ck/JLWfEBs8D7P8L9XC4HcbRknrgLNkedAjg79U9bdq3+CXpVnAp4r93rTgX5v8c1L7fdVHtcsF34mtoFb0iMau4HTVMrHlS+57U3VdXQ+Rp8Qe9LDgM8Pwjwp+WZoF/Aax+/oUBnmlXZba5Ph3apcLvhRLV42gfrwtlkY/F0tBFN1nVZ+K/UZf1d2qJaoPpHPaPC5dY8J1qJ5UzfMddsRI1TaxXQoQ1C/Elm9mtdiDHuo8eCz5JwS/LM0CfqvYfacE/8rkX5ParC6CFyGQ30QzQe0hyKvENgcEjQDDHao/xP5XrmPjpXNN+FA12rUJ9gLX3iH7S+cZukj1q9QC3CG7NuDt0jrgBI7PXQ14Zr7Y98c6j20o3s3OYwLi3ZTa1A/aE4seVttmuXaXmS1200tSu1lKeTz5w8TSUStdaF8rIOCkhUizlDIz+ZendrOUwgrdGs0AKYN7+T37RcljVmcOTl4OKEV5S/I4kzCzT03XSsGhYoPYjTK3iN2QAxGQ32kPKXoYLEf8/1I0f4mmWKC57/Tg56KZD0AEm4ePUDTXRzPAuYJ7cdjLXJC8cc7jYIXHJMywi1ojltK49qd0LvANIch0/l7qgzZX7EaXpjaHHNonFz0M9sSNlnRZCDipK5L30rF4U7zwc2pjX85hyENRpM89wY+Qd8sEnIOdD/h+UtslHSB2QGPgqYOkuZZsVJ0SvJxb+6c2BwsGJg8A8GBU+tud11X4nd+imWB/f1/w2E2tde188BnkvJOSd7bzGpFTStmAz0ntNtUnUh9cCigFuFTAz1ctFxstII9xcMh5MsMSJGflfjeKnTQPLHp0nefFdgUMXoSZQ2pgCwaniZ12RxU9bB+dj/Z83kvsWZ5xfZrBCiCQ/ZxHIcSb4DwGE49VD22pPSN3SJ95t1QadgObxEaOoBL0COmHwvGG2IsiHizm9DKQEzmwsOfljyPep+Dl3Jzhf7ECXxKb2bz3ibAKHxF7z4MoYiz7ZvQSOywxqfhtTqrUBvbVFGE8ZutisUnFbgePFf6earDYlpL3QCvEAs15xK+yigBpJC9/JhKD4D1Wy97Jz5sJrvn0U1FRUVFRUVGxm/AvGH0lNg13AR8AAAAASUVORK5CYII=>

[image28]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACwAAAAWCAYAAAC7ZX7KAAACRUlEQVR4Xu2WO2hUURCGx0eMr6BECwPBQtGQ1kIQFYKPJiSkiIqPVjsTCAbSyUKstFIRsYmv0kIMEizsbKL4QhHBF6IoEqKQEDVFJP7/nbnJ5Oy9Z1fDgsj+8LH3/mfO7Ow958xdkaqq+j+0EfSCZrAUrAdd4JoPqoCOg3HQFg6U0m4wHfAD7PVBFdCA6Hf1hQOl1AJGwXvwClwGm9x4pVQP9omu6h9pJ7gSmv+ydsj8Cl4YGmWIc9aKnpvGYIyK5twOBsElcBe8ACfmRBRrG3gLxsAN0G6fD8BL0VXbDK6DO+A12J/MVB0DU6J7uGBeXs774DnYanFJ4BfRX0s1gBGZTZSl5WCL6N7/AM6BBTY2DN6Am6DOvDPgp7unmmRuwaVyPrRrWQE2pDemq2ASrAv8UPzl7CjLnHdRtBA+5VSHzONqplppXsF5VF7OX+6+SP2iyQ6HA4GegkeBd150Lh9EqgPm7XIen2hWwbGcie6JBiyaGRY5KRrAF0pMnMfl8jorOnex89i+6LHnp2I7yyo4ljMpkpufbxy/BKct4IjzssR9lZfcF8wDFxbM78sqOJYz0WNxJ9DEkz0B1gR+KC5fXvKsgvc4L6/gWM5EHeA2WG33naIb/GgaEBFb2JPAuyCa3HcErhS9VuetMu+U86hYzhkdBM/AR9FgFh0TO8Bn0STkk+jTeyez/fUr6Aa3RFsave+if6p6wDfzODYk5eX8a3G5a+yavZLX9HiQ0t7J87Ek8PgGqzU/PeQco1dOzqqq8voNYzuag+rOcrsAAAAASUVORK5CYII=>

[image29]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABsAAAAWCAYAAAAxSueLAAABuElEQVR4Xu2UzSuFQRTGj7AgC5RCIpJC8pWNjbux8hdIsiXZsKEspNjZilKyRBa+WbmKDYVSUlhZ+EjYEBKex5x7m3fe+7pZ0n3qV3OeOTNn3nlnRiSh/6Ii11AlgyFwCHbBGiizE1Q1YAvsgAPQB5LshHTQCJbAit1haQwcgQyNO8EVyIlmiBSCe9CucTY4AYORhC5wC1bBu8QuVgDeQKvlcbUsNmJ54+DUiiku6snxvvUisYt1g09Q5fhhMSunWPwGLER7jUJixvoUVGxKzAD3fy6CD5Am5uuZM+3JEKlV36egYtxiDshz/Hn1S0CDtic9GSKV6vsUVIyniwNyHX9W/WrQpO0JT4ZIufo+BRULS/xiIW3/qhi3zFXQNs6pXyrB21ihvk8stu6aYibggGLH5wGhzwPChbA948mIc0A2XFPMXeGAesfnS2Lfq2uwbMVUs/xQbNM1oXwxF77N8lLBHRi1PF7qMyumesGz40kKeAXbboeKzxXfxUyN+8W8IFnRDHPXHkGHxnzKLsFAJKEFXIAHMZ9LuB3n4p2ID/EwOAb7Yk6t+w+pOjGnd0/M4no8vQn9GX0BChpyHReEAPsAAAAASUVORK5CYII=>

[image30]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADIAAAAWCAYAAACCAs+RAAACSklEQVR4Xu2WzUtVURTFd5YiFYjQRAmkCB0kWgMhhBqEOmniJJo0zNBJQX9BAyFxUqLWLOlPMBU1mjgp+y4NIsgg6EMMkSZRYeVa7n3f2/d4ufjuQEXuDxa+vc7xnbvOPWerSE5OThbqQiOBDui/6WEwtq3sh1qh+9B4MJbEXqgW+iY7KEgPtARNQKuyuSARb2UHBfH8ktKCzMkuCfJKtiYIj35JlBrkuWiQs9Ao9Nq8E34S2CN6hDn2CHoBdblx3zxmzTvoPGqf+WPQJ+gndAF6bH6MLEG+QkOiDYAP/Ax64ieBW6Jzq6xmo3gP9VrN3z0KfZdiEFIt+jw+yBHornkPRJvUBrIE4c74V38H+uvq06KLdjqPXIb+QU3Om5d4EMJN8EHIJfMuim7eBhiE3WuzMAiPiWdQdJEyq29bXV+YoZwxP3orhHeulCAnnReDQSZDMwUGCRceEF2Ex4Xw7rDmkfCcMv+e83gsw+9LC9LgvBgMMhWaKSTtYBhk2OrGwgyl3fw+5/FuPXU1id5wUpBjzovBINOhmULSmY6CRAuzo7E+X5ihXDG/xXnsQOFR5X8bnFfhvNQgXPg3NBMOpPBO9K14ojdwwHkjovMOWX0YWoBuFmYonPfR1cehH6Lfx5Yebc4185qtXuec6Jeu2CC1CH0QbX9JsBN9keL8z1Cb6EPw3xx6y6K7Tnjxr0IvoTf2s9vGPDWiR5v3iqFuQP1SXOe66N8qdjvWf0SfIzPcmXL7zPbHz/QqrSa8I/44ZIWtPbpvOTlbyRqG0Z77Sgp6dAAAAABJRU5ErkJggg==>

[image31]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEIAAAAWCAYAAAB0S0oJAAADUklEQVR4Xu2XWchNURTHlyHzkNkDMr5I5hdSPkKUKZSQ4YFESYYHUcpQQvKAF2MkEillDn2U4QEh4sHwSSRDIvP8/7fW/u66+x6fexL56vzr1z37v/e5d5119t5rX5FMmTJlKk4jwA3w1j5ngCp5Iwq1EOyLzUgXwA+jX9T332kQuApagAZgk2jgK/2gSC3BG3Ag7ohUFyyWSpKIi6C/a1cD98B30Nr5XttF+3+XCGqcVIJE8KG/gfugofO3iAY/03lBvUWXBJdRMYkYI5UgEVXBK9FAOzp/nXnznBd0GrSV4hMxSv5NIqqDGrGZRj3A4Mg7KRp87E+U3N5RbCKGi37XENEEnwIPwRo/yNQe7AdXDM68NtbHhwwbL6ll/mXncb+jloK74DWYA46BJ2C29TcG28AhcMK8AvGHv4BbojMmqA64JLoBUmkTcR10MY9Vit6wMAjqBJ6DSc5bIPoArazdTDSRPhGMZ4l5IRHc+GeZ99jaH8A16+cex2RVqD2iFaFr5C8DU1w7bSJ4fxADo+eD4QOGQIP4Ih5J/u9skPxEUKPNC4mguNTpbbX2ANDdrm+DjXadqMngHSiJfFaPUsk/W6RNBGdBUBPzllu7ubX5EmKdAZ9FZyS1XtIlImmf2y3axyW6K+qTbuAFGBh3iAbYJ/LSJmKo8xqZt8La3KfY3lk+Iqfjon3trL3W2sUmIqnysUIyGVwuHFMubh6cLj7YEjDerrl2n0bwCz7atV8ysULVqCgRXPtsJyX2vOieVc/aq0XHhhlCjTUvKRHTnRfEkk7VBH2DybPEUdEv8+Ka5kMkqan8OvBYIcikRIQKRJ0T3aC9WBKfgcPOWyV6b33nzTePlSmookQ8EN2c88Qyxn3hpsFgWHo+gc5unBeP2PyRg3FHgjirOHak88IM4DQP4kbGM40PnMdzLtcOzpsqem8oq5wp3GTpsVTyLVM9zZtrba8y0b2hvCrWFh2cBI/Qfh0G8Uj+UnQMT6VlYIIf4MQZ8150LJPNc8Ei0Yej91X07QQx8TxH8I/fHbBX9GzhxVnC/0NnwQ6wGUyTXNylopWFyyk8B+PtJTnxXsbBSnXE+X9NTGTIOj/Z5sGIy5FiFUpKdlpxFvzRqTJTpkwF+gnv0+gUX/eQpQAAAABJRU5ErkJggg==>

[image32]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEYAAAAXCAYAAAC2/DnWAAABY0lEQVR4Xu2WTSsGURTHj5LXYsXK1vKhbFBSsrSzUz4BeX9ZYYkPoMhWvoBCKRsrHvFQio2tWFuJ8DvdmZ6Z28NMQ5qr+6vf5pxpav6de+6IeDwej8eTdwbxEIt4ivtYwD1sjTyXlRocwVq7kWeW8Q47IrVufMbrSC0L9TiB5ziFVfF2funDD+y0G7CL63YxJQ04iyWcEROQU2zhu5gPsdnAfruYgL5nXkwg0+JgICH68ToxRzgg8YCaJf3oh4Fcijk6dfG2e7Tjk5hw1Fc8w6HoQ9+gExFOiAbi1HJNoglHcRtvxQT0JpX3jk0vPuCi/IMpCfnqGl4TE47eImnQY7SAVzgpjgfUgsd2MaBHTDDDdiOBRikHpKE6uXj16OheqMQq3ov5KcuCTtCcOHoz7eALLkn5JqrGcXzErqD2EzQQDeZCHPqXOcA2XBFzxd4Ebgb130R3zhieiCPheDwej+eP+AQIfzqziD2VyQAAAABJRU5ErkJggg==>
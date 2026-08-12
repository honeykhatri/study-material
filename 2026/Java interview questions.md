# **Java & System Architecture Interview Preparation Guide**

## **1\. Memory & JVM Diagnostics**

### **Q1: Your Java application suddenly starts throwing OutOfMemoryError. How would you investigate and resolve it?**

#### **Answer**

1. **Determine the Subtype:**  
   Inspect application logs to identify which region of memory is exhausted:  
   * java.lang.OutOfMemoryError: Java heap space — Heap allocation failure.  
   * java.lang.OutOfMemoryError: Metaspace — Class metadata leak or excessive dynamic class loading.  
   * java.lang.OutOfMemoryError: GC Overhead limit exceeded — GC spends ![][image1] time recovering ![][image2] heap.  
   * java.lang.OutOfMemoryError: Direct buffer memory — Off-heap / NIO memory exhaustion.  
2. **Capture Heap Dump:**  
   Ensure production JVM parameters include auto-dumping on failure:  
   \-XX:+HeapDumpOnOutOfMemoryError \-XX:HeapDumpPath=/var/dumps/heapdump.hprof

   *(If the process is live, capture manually using jcmd \<PID\> GC.heap\_dump /path/dump.hprof)*.  
3. **Analyze Heap Dump:**  
   Load the .hprof file into **Eclipse MAT (Memory Analyzer Tool)** or **VisualVM**:  
   * Inspect the **Dominator Tree** to isolate the largest retained objects.  
   * Trace incoming references via **Path to GC Roots** to identify why memory cannot be reclaimed (e.g., unbounded collections, static references, uncleared ThreadLocal variables).  
4. **Remediation:**  
   * **Code Fix:** Add eviction/TTL policies to in-memory collections, fix leak references, and wrap I/O resources in try-with-resources.  
   * **JVM Sizing:** If heap space is legitimately exhausted under valid load, adjust \-Xms and \-Xmx.

### **Q2: CPU usage is consistently high, but the incoming traffic is low. What could be causing this?**

#### **Answer**

1. **Identify the Culprit OS Thread:**  
   Use Linux performance tools to pinpoint high-CPU threads:  
   top \-Hp \<PID\>

   Note the Thread ID (TID) consuming the highest CPU percentage.  
2. **Convert Thread ID to Hexadecimal:**  
   printf "%x\\n" \<TID\>  
   \# Example: 12345 \-\> 0x3039

3. **Cross-Reference with Thread Dump:**  
   Generate thread dumps (jstack \<PID\> \> thread\_dump.txt) and search for the hex Thread ID in nid=0x3039.  
4. **Common Root Causes:**  
   * **Infinite Loops / Busy Waiting:** A thread stuck in an unbounded while(true) or polling loop without sleeping or waiting.  
   * **Frequent/Thrashing GC:** If heap is nearly full, GC threads run continuously in high-priority execution trying to reclaim memory.  
   * **Regex / Cryptographic Processing:** Backtracking in complex regular expressions or heavy CPU-bound crypto operations.  
   * **ConcurrentHashMap Spinlocks:** Infinite loops caused by concurrent modification bugs in older Java versions or custom unsafe structures.

### **Q3: A thread remains in the BLOCKED state indefinitely. How would you identify the root cause and fix it?**

#### **Answer**

1. **Identify the Blocked Thread:**  
   Generate consecutive thread dumps (e.g., 3 dumps spaced 5 seconds apart) via jstack \<PID\>.  
2. **Locate the Contended Monitor:**  
   Search for State: BLOCKED (on object monitor) in the thread dump:  
   "Worker-Thread-1" \#22 prio=5 tid=0x00007f WAITING  
     java.lang.Thread.State: BLOCKED (on object monitor)  
     at com.example.Service.process(Service.java:45)  
     \- waiting to lock \<0x000000076c123456\> (a java.lang.Object)  
     \- locked by "Worker-Thread-2" \#23

3. **Trace the Lock Owner:**  
   Find "Worker-Thread-2" in the dump to see why it is holding \<0x000000076c123456\> and not releasing it (e.g., waiting on long-running I/O, database calls, or trapped in an execution lock).  
4. **Fix Strategy:**  
   * **Reduce Lock Granularity:** Avoid synchronized blocks around network or database calls.  
   * **Use Fine-Grained Locks:** Migrate to explicit ReentrantLock or StampedLock.  
   * **Lock Ordering:** Ensure all threads acquire multiple locks in the exact same order.

### **Q4: Your application performs well initially but gradually slows down after a few hours. What would you check first?**

#### **Answer**

1. **Memory & Garbage Collection Behavior:**  
   * **Symptom:** Memory leak in Old Generation.  
   * **Check:** Monitor heap trends via Prometheus/Grafana or JMX. A "sawtooth" pattern where the baseline keeps rising post-Full GC indicates a memory leak, forcing GC to run more frequently over time.  
2. **Connection & File Descriptor Leaks:**  
   * **Symptom:** Open sockets or connections exhausted.  
   * **Check:** Run lsof \-p \<PID\> | wc \-l over time to monitor open file descriptors. Unclosed database connections, HTTP client instances, or file streams cause pool/OS exhaustion.  
3. **Thread Pool / Queue Growth:**  
   * **Symptom:** Work backlog filling unbounded queues.  
   * **Check:** Monitor thread pool queue size (ThreadPoolExecutor.getQueue().size()). Threads spend progressively more time waiting in queue before processing starts.  
4. **Database Indexing & Table Growth:**  
   * **Symptom:** Execution plans degrade as dataset grows.  
   * **Check:** Database slow logs. Queries that execute instantly with 1,000 rows become slow once tables reach 1,000,000 rows without proper indexing.

### **Q5: Your service is experiencing frequent GC pauses. How would you optimize the JVM and memory usage?**

#### **Answer**

1. **Analyze GC Logs:**  
   Enable GC logging (-Xlog:gc\* for Java 9+) and parse with tools like **GCEasy**:  
   * Inspect **Throughput %** vs **Pause Duration (P99 / Max Pause)**.  
   * Check whether pauses occur in **Young Gen** (high allocation rate) or **Old Gen** (long-lived object promotion).  
2. **Switch Garbage Collector:**  
   * Move from legacy collectors (Parallel/CMS) to modern low-latency collectors:  
     * **G1GC** (Default in Java 9+): Good general balance (-XX:MaxGCPauseMillis=200).  
     * **ZGC / Shenandoah**: For ultra-low latency requirements (![][image3] pauses) handling large heaps.  
3. **Optimize Code Allocations:**  
   * Avoid short-lived object thrashing in hot loops (e.g., heavy String concatenation, unnecessary autoboxing).  
   * Utilize StringBuilder, object pooling for heavy objects, or primitive collections where applicable.  
4. **Tune Generation Sizes:**  
   * Increase Eden/Young Gen (-XX:NewRatio) if objects die young, keeping them out of Old Gen.  
   * Adjust Survivor ratios (-XX:SurvivorRatio) to prevent premature promotion.

## **2\. Concurrency & Performance Tuning**

### **Q6: A HashMap becomes a performance bottleneck under heavy load. What are the possible reasons?**

#### **Answer**

1. **High Hash Collisions:**  
   * **Cause:** Overriding equals() without a well-distributed hashCode() implementation.  
   * **Result:** Keys map to the same bucket. Lookups degrade from ![][image4] to ![][image5] via Java 8+ balanced tree conversion.  
2. **Frequent Resizing (Rehashing):**  
   * **Cause:** HashMap created with default initial capacity (16) and load factor (0.75) storing large datasets.  
   * **Result:** Repeated array re-allocation and re-hashing operations during runtime.  
   * **Fix:** Set initial capacity appropriately: ![][image6].  
3. **Thread Safety Misuse / Lock Contention:**  
   * **Cause:** Wrapping HashMap in Collections.synchronizedMap() under high multi-threaded read/write load.  
   * **Result:** Single lock serializes all access.  
   * **Fix:** Replace with ConcurrentHashMap which utilizes lock-striping and CAS (Compare-And-Swap) lock-free reads.

### **Q7: Multiple threads are corrupting shared data. How would you ensure thread safety?**

#### **Answer**

1. **Immutability (Preferred):**  
   Make state immutable using final fields and returning unmodifiable copies. Immutable objects are inherently thread-safe without synchronization locks.  
2. **Atomic Variables:**  
   For single values (counters, state flags), use lock-free atomic primitives from java.util.concurrent.atomic:  
   AtomicInteger counter \= new AtomicInteger(0);  
   counter.incrementAndGet(); // Thread-safe CAS operation

3. **Explicit Locking:**  
   Use ReentrantLock or StampedLock for read/write synchronization:  
   private final ReadWriteLock rwLock \= new ReentrantReadWriteLock();

   public void updateData() {  
       rwLock.writeLock().lock();  
       try { /\* modify shared state \*/ }   
       finally { rwLock.writeLock().unlock(); }  
   }

4. **Thread Confinement:**  
   Isolate state to execution threads via ThreadLocal variables or stack-confined local variable execution.

### **Q8: Your API works perfectly in your local environment but fails in production. What areas would you investigate?**

#### **Answer**

1. **Environment Configuration & Infrastructure:**  
   * Active Spring profiles, environment variable mismatches, database connection pool limits.  
   * Firewall, proxy, VPC routing, SSL/TLS handshakes, CORS settings.  
2. **Concurrency & Load:**  
   * Race conditions and thread-safety bugs that only trigger under true parallel concurrent requests.  
   * Connection pool depletion (HikariCP/HTTP client connection limits).  
3. **Data Volume Edge Cases:**  
   * Local DB tested with 20 rows; production DB contains millions of rows causing query timeouts or memory overflow.  
4. **Distributed Context / Dependencies:**  
   * DNS resolution delays, load balancer sticky session behavior, downstream microservice rate-limiting.

### **Q9: You suspect a memory leak in your application. How would you confirm it?**

#### **Answer**

1. **Monitor Long-Term Heap Trends:**  
   Observe heap usage after Full GC over time. If Old Generation memory baseline steadily increases without stabilizing post-Full GC, a memory leak is present.  
2. **Trigger Force GC in Staging:**  
   Run explicit GC via jcmd \<PID\> GC.run or JMX. Check jmap \-histo:live \<PID\> to observe which instances remain alive in heap.  
3. **Compare Heap Snapshots:**  
   Take two heap dumps 1 hour apart under production load and run a **Heap Dump Delta/Diff Analysis** in Eclipse MAT:  
   * Look for objects with a growing count and uncollected references.

### **Q10: A service becomes randomly unresponsive without crashing. What could be happening behind the scenes?**

#### **Answer**

1. **Long Stop-The-World (STW) GC Pauses:**  
   Full GC execution freezes all application threads. The process remains active, but external callers receive timeouts.  
2. **Thread Pool / DB Connection Starvation:**  
   All execution threads are blocked waiting for external calls or database pool acquisition (HikariPool \- Connection is not available).  
3. **OS Swap Thrashing:**  
   When physical host RAM is exhausted, the OS swaps JVM heap pages to disk swap space, slowing JVM memory access drastically.  
4. **Deadlocks:**  
   All request-handling threads locked waiting on resources, preventing incoming request processing.

## **3\. Concurrency Tools & Resiliency**

### **Q11: You detect a deadlock in production. How would you diagnose and eliminate it?**

#### **Answer**

1. **Diagnosis:**  
   Run jstack \<PID\>. The utility parses thread dependency graphs and appends an explicit deadlock diagnostic:  
   Found one Java-level deadlock:  
   \=============================  
   "Thread-1": waiting to lock monitor 0x0001 (held by "Thread-2")  
   "Thread-2": waiting to lock monitor 0x0002 (held by "Thread-1")

2. **Elimination Strategies:**  
   * **Lock Ordering:** Enforce a strict global hierarchy for lock acquisition order across all execution paths.  
   * **Timed Lock Acquisition:** Replace intrinsic synchronized blocks with ReentrantLock.tryLock(timeout, timeUnit). If the lock cannot be acquired within the timeout window, log a failure and release held locks to prevent deadlocks.

### **Q12: Logs show inconsistent behavior for similar requests. What could explain this?**

#### **Answer**

1. **Load Balancing Across Heterogeneous Instances:**  
   Requests directed to instances running different deployment versions, canary releases, or mismatched feature flags.  
2. **State Mutability in Singletons:**  
   Shared Spring Singletons containing mutable instance fields modified concurrently by requests.  
3. **Thread Safety Issues in Utilities:**  
   Using non-thread-safe stateful utilities (e.g., SimpleDateFormat, un-synchronized legacy collections) shared across requests.  
4. **Stale Cache / Cache Inconsistency:**  
   Distributed cache returning stale/inconsistent data depending on which cache node is servicing the key.

### **Q13: Your Java application crashes without any obvious exception or error message. How would you debug it?**

#### **Answer**

1. **Inspect Linux OOM Killer Logs:**  
   Check OS kernel logs to see if the JVM process was terminated by the OS:  
   dmesg \-T | grep \-i oom  
   \# OR  
   cat /var/log/messages | grep \-i "killed process"

   *(Occurs when total process footprint—Heap \+ Metaspace \+ Native Threads—exceeds container/OS limits).*  
2. **Locate JVM Crash File (hs\_err\_pid.log):**  
   If the JVM crashes due to native memory/JNI errors, an error report is generated in the working directory:  
   cat /app/hs\_err\_pid\<PID\>.log

3. **Check Signal Interruption:**  
   Verify if process was sent SIGKILL (kill \-9) by orchestration platforms (e.g., Kubernetes Liveness probe failure termination).

### **Q14: Database operations are slowing down your application. How would you identify and optimize the bottleneck?**

#### **Answer**

1. **Identify Slow Queries:**  
   * Enable Database **Slow Query Logs** or inspect APM tools (Datadog, New Relic).  
   * Run EXPLAIN ANALYZE \<query\> to evaluate the execution plan.  
2. **Query & Schema Optimization:**  
   * Add composite/covering indexes for columns in WHERE, JOIN, and ORDER BY clauses.  
   * Avoid SELECT \*; return only necessary columns.  
   * Address **N+1 Query Problems** in ORM frameworks (Hibernate) using JOIN FETCH or batch fetching (@BatchSize).  
3. **Connection Pool Optimization:**  
   * Tune HikariCP pool parameters (maximumPoolSize, minimumIdle, connectionTimeout).

### **Q15: Your thread pool gets exhausted under peak load. What steps would you take to troubleshoot and fix it?**

#### **Answer**

1. **Troubleshooting:**  
   * Inspect thread stack traces to identify what active threads are waiting on (e.g., un-timed HTTP client calls, DB query locks).  
   * Verify if the thread pool queue is bounded or unbounded.  
2. **Fix Steps:**  
   * **Enforce Timeouts:** Add timeouts to all external network/REST/DB interactions.  
   * **Configure Bounded Queues:** Replace unbounded queues with bounded implementations (ArrayBlockingQueue) paired with rejection policies (CallerRunsPolicy or custom fallback).  
   * **Segregate Pools (Bulkheading):** Isolate critical application tasks into dedicated thread pools so low-priority tasks cannot starve core workflows.

### **Q16: You need to build a highly concurrent system without compromising correctness. Which Java concurrency tools would you choose?**

#### **Answer**

| Requirement / Pattern | Recommended Tool |
| :---- | :---- |
| Lock-free single variable mutations | AtomicLong, AtomicReference, LongAdder (high write throughput) |
| Read-heavy shared memory access | ReentrantReadWriteLock or StampedLock (optimistic reading) |
| Lock-free concurrent collections | ConcurrentHashMap, ConcurrentLinkedQueue |
| Coordination across worker threads | CountDownLatch, CyclicBarrier, CompletableFuture |
| High IO-bound concurrency (Java 21+) | **Virtual Threads (Executors.newVirtualThreadPerTaskExecutor())** |

## **4\. Distributed Systems & System Architecture**

### **Q17: Your application processes duplicate requests. How would you design the system to prevent this?**

#### **Answer**

1. **Idempotency Key Pattern:**  
   Require clients to pass a unique Idempotency-Key HTTP header (e.g., UUID) with requests.  
2. **Distributed Cache Verification (Redis):**  
   * Before processing, execute atomic Redis SET key value NX PX \<TTL\> (Set if Not Exists).  
   * If the key exists, return the cached result or return an HTTP 409 Conflict / 429 Duplicate status.  
3. **Database Unique Constraints:**  
   Apply UNIQUE constraints at the database level on business parameters (e.g., transaction\_id, order\_reference).

### **Q18: Your cache occasionally returns stale data. How would you address cache consistency?**

#### **Answer**

1. **Cache-Aside with Invalidation:**  
   When updating data, update the primary database first, then explicitly delete (invalidate) the cache key rather than writing the new value directly to cache.  
2. **Short Time-To-Live (TTL):**  
   Attach appropriate TTLs to all cache entries as a fallback mechanism for missed invalidation events.  
3. **Change Data Capture (CDC):**  
   Use CDC pipelines (Debezium \+ Kafka) to stream database transaction commit logs directly to clear/update cache keys asynchronously.  
4. **Write-Through / Read-Through Cache:**  
   Delegate persistence entirely to a caching layer interface that manages synchronous database reads and writes.

### **Q19: Even after adding more application instances, your system doesn't scale as expected. Why might that happen?**

#### **Answer**

1. **Centralized Database Bottleneck:**  
   The database has hit maximum connection, IOPS, or CPU limits; scaling application instances increases lock contention on the database layer.  
2. **Stateful Application Design:**  
   Session state saved in local memory prevents load balancers from distributing load evenly across instances.  
3. **Downstream Service Rate Limits:**  
   Third-party APIs or internal microservices downstream choking on higher traffic volume.  
4. **Amdahl's Law:**  
   Serial execution paths in application code (global locks, single-threaded processing queues) limit speedup capabilities regardless of horizontal scaling.

### **Q20: You need to trace a single request across multiple services and layers. How would you approach it?**

#### **Answer**

1. **Distributed Tracing (OpenTelemetry / W3C Trace Context):**  
   * **Trace ID:** A unique identifier generated at API entry point identifying the global request journey.  
   * **Span ID:** A unique identifier representing individual execution units within specific microservices.  
2. **Context Propagation:**  
   Propagate headers across HTTP/gRPC boundaries via traceparent standards.  
3. **MDC Injection:**  
   Inject Trace ID into logging context via SLF4J / Logback **MDC (Mapped Diagnostic Context)**:  
   2026-08-12 20:51:48 \[TRACE-12345\] INFO com.example.Service \- Processing order

4. **Aggregation & Visualization:**  
   Export traces to centralized collectors (**Jaeger**, **Zipkin**, or **Datadog**) to visualize end-to-end trace latency graphs.

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADsAAAAZCAYAAACPQVaOAAAD60lEQVR4Xu2XfWiWVRjG37VZllpmzOk+3vPuI2ZDsxxoYug2BCtR/0gKQgJFpA8IsZaRgVkTxETEiubAjzEm2mzOjJCURZihIKl/iaLgHwoh/ZMigiD1u3rOPY9nm+0dshy8F1y8577v6z7n3OfjeZ43lcohh/8NzrmJ6XT6G36/5LcmjhuIf5LJZCbF/qFAHoNvhOfgJSaxt6ysrDgWEXteMX5/gN9SzHu48y1eWFg4mvh5/HPJr0RzGTbK7yX52A1wH+y0vCEFk2tm8COaVFVV1SO0t8JuQnmmccmO/QIrvCuPwr6XNtAsh6fMRrsWzQZ8LbAd+wTco0UoKSkpNd2QgYHfgH8ziRXmU9HyKRboPoONZgulpaVP47tlO0dh27APW5zdXRjnYL8L3wl9/QLhfHiUjufEscGAInf5wl4J/S45gu1mM16rdiXUsDtPKVe/sml/BY9YnJxF2KvM9ovzayo4Mf8JOqkj6WdNAGbieDagnw5NmG7mRf4L8KzZxNf5RemgPdJr3mcBukyj04Hv9yDnU/iSN/Vc6KbgKRbPCi45gsfhF7a62YLc7b5Ym5T5/4TXzPa7csMXfIbCPuT3N/ImmIb2WHwXiL1YWVk5nvaxlH+AueQ+f27aQUOd09EOuCnbi+/8nWWiS81XXl4+1Rcl/9hAqyfpXxbTeLgLLO41emL/pCNPP04+f9yP2Ym4L9BA8DvYxkDPxvF+kK97Cw8VFRWNYgcfZVJb6OOKCqqpqXnYhNgbdZxhqxVM3s6ws76A7mty6sym/RY8QO7iQDY4UGg1A3TC/QNdTXQr0Z+E7bpXLnlAXbE47TVaFLNpz3LJvVbBC8wfg7lMR9NiNu0m9M2MMU4LhV0f6rMCHTyZSd5tV+H6VDZPvgDk3oYdaqtP2tfgtEhT7v0apxdqa2tH6MQoX3ZFRcUTaK/Dmd5O0959d9YAoONHYiM8TeertXKxph8UaMfIe9UcLNZzLjmm//p4X06WrWN+Jy0B/jYtbuwX8H8EXzebXZ7t+33GfC55FQ0MWj06fJukM3CVio4194IG9hP4MfA1wUvqW3Z1dfUY7Jvw5TuZPdpuF72jvV+7ftcnIfN8QWOlg29m5YeaPuE/6/Q41z1bg/14rBkItFvkX2UCS2T7u3hZv6HOL+gf+N/EfMh/ZX0A20KdQYXy+ikLfcXFxY/hv21962mdjj5UeoGEZfAs/HiwRYagkBmaNDwK94UrHwL/Atjlknf7wfCIhkDzWjr5k9AL5G32C6SPDL3jG2JNDwjWp5MP7J7334MEnRTmdiAV/BsKoavhks/Kiy749h620FM39uWQQw455DAc8Q/0CguCtpd7uwAAAABJRU5ErkJggg==>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADEAAAAZCAYAAACYY8ZHAAADD0lEQVR4Xu2WWWhTQRSGb7Vq3dcQadPcJgQiVQSJ2MciCvro9iCIC1YpLmCtqLih4oNIFZUWEUREK3V5KEIfBBVRCkFcWioubwZcXvom4oOC1O80M+V0GpM2xA3yw8+dc+afM+fMnZl7Pa+IIvpRWVm50Pf92/BweXn5LLdfEAgEJtF/geZot++3IhaLjQuHwxeZvBd+gNcrKipCWkN/Av+baDQarqqqWmF0qzyTrCSPZg2+Lvob9Ng/Aia+AZsjkUiQ50r4GaYoborSXCO588p+ALfDVtgOn9B/i2fSK9RbYMWmEnSTlyMgky5mBR/TLFE+Sa4PNinfW3hE2aeJX2Nt42tjIeZrX15g9QIkdZKAz+CW6urqsa5GA+1+dN9JaLf1yVYyRaSsj/6XaI9am74zckaUXSfzWjsvhEKhGSb5HrhT9rmryQS0jZIwY69YH+3ppohepWulkHPWpn1P3rZpz5ZFI4fxtn9EkH1LgBMShGBrcY1yNdmQSCTGMG6j3v/YtaaIh8pXg53iLc2kyCW0L9k+KRDfUmsPG1K1WcUuAmzFVepq8oW5qfpIfJn2yyLhfwRbaJcZXy28qnU5YVaunkBJfwTbZrgg9hzi/vDVIc6CUnlb9psRj8cnYzexCDd5LnDFA+D0L/LTd/ReuxqFAslMIG6PPh/ZIDsB7Xpjlpi3tNlc1Z1ytgYN0DBb6SB8TSENBSpGkmiDl70c17IAXQS2W1vOBPYXz5xJKY68tg0M+BXMLXIIdsM9ed8OXv82Oka8O566GLDPKskgMF8HK+4rW/L4aG2u33nYzdbOCfPbsItBr0jmQDAYnOhqsoFxqxn3VI+T70s4/REcAvTrYKP2od2H75O1TREtWjMskMg0eIrB7ySoHDRX4wLdXD/9m/EC3ofP8b3n+Q22unqZA/9dz9ly+Jfj/2r9xNiAvUNrRgS5LWR7yOrmur2YqMlPfxOGkPHHM+ibSTDh+uXWpC/JmHpzQXTKB9jV/XXIzShv2vVbyB8uyXfA7kyF/hOggLJcb7aIIooo4v/ET4/qxQ3lLlOHAAAAAElFTkSuQmCC>

[image3]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEkAAAAZCAYAAAB9/QMrAAADcUlEQVR4Xu2XS0hVURSGr/am90MM9d6jV+mS1CDsQYMobFQ0MGhQYFRgVBIUhdEboSIcRERKD5IeNGlgFIRRQY+BkVZGopAFIRT0pFkOjLBvcdeh5cajV3Ngcn742Wf9e+291/7vPo8biYQIEWIkIR6Px2hGubogNzd3tud5tfBRLBZrhFvdnBGLwsLCsWx8ASZU0n6PRqML3ZysrKxZ9LfQXy5xfn5+lOt3MsZJ/X/AiZjKBjZHAk6FBZv9AOvhA9jdm0nop8QkqxFvF1OLiorGWH3Yo6CgIIPb4CTFP4dlckrcnCAwbl8fJnVgyg1HK9b8ZVYftsjJyZmh5ryGOzFrnJvTH4JM0mdRN+0Fq5NfJDo8bPVhB8yYQpHH5OSwifVI6W5OqggySWI1o9rq/DDzRWfcZav7oK8MftWx5dRXQlsD2+BZfRYWo9+mfQFvMlehmSKNvh3a3wCfCuVRYnKCQYETGLAHNutbZrSbM1AEmUSRy3WjPUySDal+3eo+6I/DUs15yTzbRJeXAHEnfffgeX2mpUkOvOaPJ38FbPJjzJlD/2cZ72u9QiaUxbykq4O6rYIQZBLaUt1oD5OI54pOPVetbpGdnT1Tx961upd8LPyw9bP+ObSfJj5N/DBiDgBxHetN8+NekZeXt9hLvo0qSB7v9v8LjEmLrM6aCd1ojdXJmye6bMbqFrIhNbLK6mjN8LGjVcMuP2bMJl23Hd4h3p3yodBb7SBsk4FDZVaQSXp7SLG1Vpc81Y9Y3SKRSEzWnBNW95ImySmxmpj0y0jpus9OnUPMbhrQftnUdAYegq/gXjHPzRkIfJPktLp9FPaWvjqrEa/S4ldb3SIjI2OS5qRqUrcfU88auV3lWj5e5UDQ/5t2y99RKUKOIBPuYoJWJjiQmZk50c1JBb5JzLHE7UM/Dtu5TDNaBfzU18ekf7sNxiSuL1HTRpsjD3vm3G+1AUEKglVM/l42LEfdzekLjDkqRdKudPvkiNPXQFsisZxaOV3klrq5FvJfUI0/Y2R5k7UzttFosv4VyfV/ZDGJcS3+20x+DLQvQ/Lxqv+zKmFTKg86La5DClR2oT3x9H+aD/lglV9R8y/CtbbfhZf8Tvpm5pU3srwp3xitVbVnRvvIOhtoq+UOgbeI7xPXc73OXSdEiBAhQoQIESJE//gD7X0ebyMhSecAAAAASUVORK5CYII=>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACsAAAAaCAYAAAAue6XIAAAC4klEQVR4Xu2WTYhNYRjHrxkfIURyud8fo9ENoy7ZSINIElaSlGShUIpENlYkG4sZZaFJXSnR5GsjQ4ksyEoU0awwLIyPZkFp/B7znts7f/fOPerexdT91dO55/9/zvM+73vOee+JRJqMA4rF4qR0On09n88n1atGKpWaTdxoa2ubqV5DodHzmUxmm+oB+FnVDJpdR9zlZ6t6DYFGdhK9qre3t89gAp14F4lB9QPwesg7rnpN7JZw8QniCgVucnxAPGb2xyKVZ9+C/57cjb7I+TL0T1aHeEV89X0fcldabiKRmKpeVWhoFxe+4cIjnLYEeiwWm4v2nOhjMlO8SyLJZHIL+lt+TvB1H/zbYzVr4PcTB1WvCIlniY80u0g9A28tMcyETopeIrp8TQnTLHUvkXNf9X8gaa81ks1mN6gXYCtKzm/ima9z/rrWioRp1vXwTfVR2EqSNEQ8Uc8nGo1OtwkRnwMtl8vNMo0aW/1cJUyzLNRqV2u+emVI6HJJ+9TzCYoRjzytwzTz/FwlZLNLrRbvwGL1AlpJGHBNVNwHA5jMGZdXfj4pvMI03uIlfq7imh3zFnOXUlaLcTrV+wtv+TTXwDCnE9UPsFuTHnlUfvmNeSvb4ecrYZqNx+MJq2V/EuqVIeGFW52qexx+t5v1qI3b/lpds2Eeg++q+9jtt1ocl6tXhoRTlkRsUs9A3+9mfEG94KXD26yej2v2h+o+1FhltViAeeqVcY/CO+Kl/yYWCoXJFDiN/pM4HKmy6eP1k3dIdR9y7hFDNjn1Ahh7d9rbaarCbYwy4DniYWbkL7bE8SrHo8QCzffB7yEuq85jNcfq4Q3airn4Yo3bKmo+ejdj3lK9rjDAHlsR+0RU73+gzlNih+p1xX34DLBa29ULC3dhITU+RMbYkeoGAx0g7qgeFvsusGdW9UZhn4m9DLpejVpw3RqipHpDsX2aQa+xT8bUq4a9hFzTZzuSek2ajHf+AI8lyAtaeSvZAAAAAElFTkSuQmCC>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEsAAAAaCAYAAAD/nKG4AAAEyElEQVR4Xu2YeYiVVRjGr0v7SjSNznbuLDE1EELTAkGBQRERqQRFVmQGFdlmmWVgga30R1kWRUgFIy2MTCmRiGWbCW1SjVpNiX9EKhKBhH8kxPR7Ouc077x81xlnGLnEfeDlfud5n/Oec96zfd8tlWqooerR3d19RAhhdXt7e7P3VRtaWloWY9d7/rCBRL1YLpdn67m1tZViWEqHnuT3Ma+tAkymXx9hM71jwkGjc7G+XCZJbZRXYoPYBqutFjQ3N7fTt12dnZ0neN+o0dHRcSJBHsLeYKWs4XcjtokEPIB7iteX4iz9hvYy76DOF9WaLIE+r6V/izw/KmgfE2CAAPdRnJz5hoaGU+G+wT4gmUeZKpqhK+F/4XGS5QX4z6s5WfRtvia6q6vrSO87KKj0NLabZJ3hfQK+i7FBEvqI43uwFZbLINan1ZyspqamDo1JY/O+ikB8sypxMF/qfRlaUWj+xr6yPOWfsDssl1GULM0i3KPYlhAP2Q9ZnedYjUDdefj6VJ8Jeh27M8QJ/bGuru54rx8riLczxJ00MrSSEO/HNnufRX19/XEhzsLezLW1tZ0kjhizrDbDJyu9XnyMrSyl8y/EFbuPhF1o6j0Ht5XHqUnzggbFSjhd8fg9JWszSOZd+H7Aeql/ss5Yft/GvuT5JfXV1xHwrVd8zxcC4Yo04Fu9z4JVd5F02GeGmyFOPqvN8Mni+fakr7c6uDc1UCUzlfcFc7vyPCe1PWeo1hA04dhys622YhfIx+90cfhv8/UEJVTte74IUxDuSQ20eqcFQZ9Kuv/OJ1bDueLo5FlWm1GQrE3YDqsRmN2HU+yzk24X9l72E2e2/OiuGKo1BHzLmIDz+L0qxbku+zg+6sRVSha+V2wfK4Jb7tgUfLCUlnwRaGhaiFv1gE2MWVkzrD6jIFmamJ+tRtCWSf2Ym3RLsd8bGxubKE7F/1qIx0TFPgrluH3/zCs0cTcqtlad1WYQ+2X8Gz1fCIT9Kdgx3pcR4pmh2XnQ8vq0EX8I2/BrbLfVJH6Z4tDxS1Sm3sLEbQ7xAH5mNIc6ui3UXeO4dcEcHR4hHgHveL4QCB9XR7HLvU8I6ZzRDHhfPvQPsj2GvWcxkCXSa2s43Srsj/y+w/NqJqDTakaCzsE0jgWZo71y6t8tpXjkrDJV/kWIyXze84VIW3EHto3Y0zKvjtPIE/B/YfeWCl46BXw70d3teTAJ37fB3LJKLtpP4F7NnF4bKO+n7XmZU+fRvRvi9+VifNeOlDxplBi73eCuEZd2wPyUtGFAM1CucJ4VQrNCoGc1EC1jAveU4y1xPzbd6y008OBmjDjdcNvV0WT9cF3y6VuM2Mvhfg3xXUvX/bBbjvJMU9fa+wz8NKvNwLeIuGstp7bge2l7Pb6FJfNVImhxKC6/51t+wkBDN9HgXnuojgfEOhM7oLisksbMp8tEE9Bj9eMBbcwi3jbPTxjSh/ceZu9q7xsLQvya6Pe8wODuwfed58cKYq1STM9PKGh0QTDvReOBbj0li+TfYHmtAmygwvl4yEhfA/3EPNr7Jhr6m6avJV3944W2H7HeYiDfE3dDiC+z27U1vXaMUH/X5XP0sEPvaXSgl9utwfuqDSR9SdncvjXUUEMN/zf8A5hya7N7JmTBAAAAAElFTkSuQmCC>

[image6]: <data:image/png;base64,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>
# **Question 6 Deep Dive: Design an API Rate Limiter (Distributed System)**

While a standard rate limiter focuses on core algorithms (Token Bucket, Sliding Window), an **API Rate Limiter for Distributed Systems** addresses the engineering challenges of enforcing rate limits across global multi-region deployments, high-throughput microservice meshes, and multi-tenant API Gateways handling ![][image1] requests per second (QPS) with sub-millisecond overhead.

## **1\. Requirements & Distributed System Constraints**

### **Functional Requirements**

> * **Multi-Tier Throttling:** Enforce limits by API Key, IP address, User ID, Route Endpoint, and Tier (e.g., Free: 60 req/min, Enterprise: 10,000 req/min).  
> * **Multi-Region Coordination:** Enforce rate limits globally or per-region without incurring cross-continent network latency penalties.  
> * **Granular Rule Engine:** Dynamic configuration changes without restarting Gateway nodes.  
> * **Standardized HTTP Responses:** Return HTTP 429 Too Many Requests with RFC 6585 and IETF rate-limit headers (RateLimit-Limit, RateLimit-Remaining, RateLimit-Reset).

### **Non-Functional Requirements**

> * **Ultra-Low Latency:** Rate-limiting overhead must remain ![][image2] (p99).  
> * **Extreme Availability & Resiliency:** ![][image3] uptime. Outages in rate-limiting infrastructure must **never** bring down upstream core APIs (Fail-Open philosophy).  
> * **Linear Horizontal Scalability:** Scale from ![][image4] to ![][image5] QPS seamlessly by adding nodes.  
> * **Consistency vs. Performance Trade-off:** Eventual consistency across regions to protect latency, with configurable strict consistency for high-value endpoints (e.g., payment submission).

### **Back-of-the-Envelope Estimation**

> * **Global Traffic:** ![][image6] across 3 regions (US-East, US-West, EU-Central).  
> * **Gateway Instances:** ![][image7] API Gateway proxy instances per region.  
> * **Cache Storage Overhead:** ![][image8] active tokens/keys per hour ![][image9] of distributed memory (easily managed by a modest Redis cluster per region).

## **2\. Integration Topologies: Where Does the Rate Limiter Live?**

Choosing the architectural placement of the rate limiter heavily dictates system latency and operational complexity.  
\+-----------------------------------------------------------------------------------+  
| APPROACH 1: Centralized Rate Limit Service                                        |  
| Client \-\> Load Balancer \-\> API Gateway \-\> \[RPC Call\] \-\> Rate Limiter Service \-\> DB|  
\+-----------------------------------------------------------------------------------+

\+-----------------------------------------------------------------------------------+  
| APPROACH 2: Gateway Middleware Filter / Sidecar (Recommended at Scale)            |  
| Client \-\> Load Balancer \-\> API Gateway Node (Local Cache \+ Async Sync) \-\> Service|  
\+-----------------------------------------------------------------------------------+

| Dimension | Option A: Centralized Service | Option B: Gateway Middleware (In-Process) | Option C: Service Mesh Sidecar (e.g., Envoy) |
| :---- | :---- | :---- | :---- |
| **Execution** | Separate microservice called via gRPC/HTTP before API handler. | Filter module compiled directly into API Gateway (Kong, NGINX, Spring Cloud Gateway). | Out-of-process sidecar proxy attached to each application container. |
| **Latency Overhead** | High (![][image10] network hop per request). | Ultra-low (![][image11] internal memory/local cache read). | Low (![][image12] localhost socket hop). |
| **Language Dependency** | Agnostic (gRPC interface). | Coupled to Gateway framework (Lua/C++/Java). | Agnostic (Envoy Rate Limit Service protocol). |
| **Scalability** | Must scale independent cluster of limiter nodes. | Scales automatically with API Gateway fleet. | Scales automatically with pod replicas. |
| **Verdict** | Best for small microservices architectures. | **Best for high-volume public APIs.** | Best for internal microservice-to-microservice throttling. |

## **3\. High-Level Distributed Architecture**

                                      \+-------------------------+  
                                      |   Global Anycast DNS    |  
                                      \+------------+------------+  
                                                   |  
                        \+--------------------------+--------------------------+  
                        | (US Traffic)                                        | (EU Traffic)  
                        v                                                     v  
          \+---------------------------+                         \+---------------------------+  
          | Region 1: US-East         |                         | Region 2: EU-Central      |  
          |                           |                         |                           |  
          |  \+---------------------+  |                         |  \+---------------------+  |  
          |  | Load Balancer (ALB) |  |                         |  | Load Balancer (ALB) |  |  
          |  \+----------+----------+  |                         |  \+----------+----------+  |  
          |             |             |                         |             |             |  
          |             v             |                         |             v             |  
          |  \+---------------------+  |                         |  \+---------------------+  |  
          |  | API Gateway Fleet   |  |                         |  | API Gateway Fleet   |  |  
          |  | (Local Memory Cache)|  |                         |  | (Local Memory Cache)|  |  
          |  \+----+----------+-----+  |                         |  \+----+----------+-----+  |  
          |       |          |        |                         |       |          |        |  
          | (Read)|          |(Async) |                         | (Read)|          |(Async) |  
          |       v          v        |                         |       v          v        |  
          |  \+---------------------+  |                         |  \+---------------------+  |  
          |  | Regional Redis      |  |                         |  | Regional Redis      |  |  
          |  | Cluster (Lua)       |  |                         |  | Cluster (Lua)       |  |  
          |  \+----------+----------+  |                         |  \+----------+----------+  |  
          \+-------------|-------------+                         \+-------------|-------------+  
                        |                                                     |  
                        \+-----------------------\> \+ \<-------------------------+  
                                                  | Async Delta Sync (Kafka / WAN)  
                                                  v  
                                      \+-------------------------+  
                                      | Dynamic Config Engine   |  
                                      | (Control Plane / Etcd)  |  
                                      \+-------------------------+

## **4\. Deep Dive: Redis Cluster Sharding & Hash Tags**

When handling ![][image13] QPS, a single Redis node becomes a bottleneck due to single-threaded execution. We scale horizontally using **Redis Cluster**.

### **Key Partitioning and Hash Tags**

Redis Cluster maps keys to ![][image14] hash slots using CRC16. To run multi-key Lua scripts or complex multi-field rate limits (e.g., checking both IP rate limit and API Key rate limit), keys must reside on the **same cluster node**.  
We enforce slot co-location using **Hash Tags {}**:  
Key Format: ratelimit:{user\_tenant\_id}:route\_id  
Example 1:  ratelimit:{usr\_8912}:/v1/checkout  
Example 2:  ratelimit:{usr\_8912}:/v1/products

Because {usr\_8912} is enclosed in braces, Redis hashes *only* the string inside the braces to assign the slot. This guarantees all rate-limiting state for usr\_8912 lands on the **exact same Redis shard**, enabling atomic multi-rule evaluations via single-shard Lua scripts.

## **5\. Distributed Synchronization: Local Batching vs. Cross-Region Latency**

Calling a central Redis cluster synchronously on every single request across the globe introduces network latencies (![][image15] inter-region hops), destroying API performance.

### **Strategy A: Local In-Memory Batching (Asynchronous Counter Flushing)**

Instead of atomic remote increments per request, Gateway nodes aggregate local counts in RAM and flush deltas to Redis periodically.  
Request 1..15 \---\> \[ Gateway Node A (Local Memory: Count \+15) \]   
                         |  
                   Every 50ms Flush Delta (+15)  
                         |  
                         v  
              \[ Regional Redis Cluster \]

#### **Mathematical Formulation for Local Batching**

Let ![][image16] be the global limit, ![][image17] be the number of active API Gateway nodes, and ![][image18] be the sync interval.  
Each Gateway node reserves a local buffer ![][image19]:

> * ![][image20]**Pros:** Zero network calls for ![][image21] of requests. Processing latency ![][image22].  
> * **Cons:** Over-throttling or under-throttling during traffic surges when requests hit only one gateway node.

### **Strategy B: Local Read, Distributed Write with Leaky Bucket / Token Sync**

> 1. Read local counter from node memory.  
> 2. If close to threshold (![][image23]), trigger synchronous verification against regional Redis.  
> 3. Asynchronously aggregate usage counters across regions via **Kafka / Event Streaming** for daily/monthly quotas.

## **6\. Production-Grade Redis Lua Script: Sliding Window Counter**

This production-grade Lua script implements an atomic **Sliding Window Counter** algorithm. It handles window roll-overs seamlessly without race conditions.  
\-- KEYS\[1\]: Rate limit key (e.g., "ratelimit:{usr\_101}:/v1/orders")  
\-- ARGV\[1\]: Current Epoch Timestamp (seconds)  
\-- ARGV\[2\]: Window Size in seconds (e.g., 60\)  
\-- ARGV\[3\]: Maximum allowed requests in window (e.g., 100\)

local key \= KEYS\[1\]  
local now \= tonumber(ARGV\[1\])  
local window \= tonumber(ARGV\[2\])  
local limit \= tonumber(ARGV\[3\])

local clearBefore \= now \- window

\-- 1\. Remove timestamps older than the sliding window  
redis.call('ZREMRANGEBYSCORE', key, 0, clearBefore)

\-- 2\. Count total requests in the remaining window  
local currentRequests \= redis.call('ZCARD', key)

\-- 3\. Check if count exceeds limit  
if currentRequests \>= limit then  
    \-- Return {Allowed=0, CurrentCount, RetryAfterSeconds}  
    local oldest \= redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')  
    local retryAfter \= 0  
    if \#oldest \> 0 then  
        retryAfter \= math.ceil((tonumber(oldest\[2\]) \+ window) \- now)  
    end  
    return {0, currentRequests, retryAfter}  
else  
    \-- 4\. Add current request timestamp to Sorted Set (Member=now:nonce, Score=now)  
    local nonce \= redis.call('INCR', key .. ':nonce')  
    redis.call('ZADD', key, now, now .. ':' .. nonce)  
      
    \-- Set TTL on the set to prevent memory leaks  
    redis.call('EXPIRE', key, window \+ 5\)  
      
    return {1, currentRequests \+ 1, 0}  
end

## **7\. Fault Tolerance & Resiliency Patterns**

### **1\. Fail-Open vs. Fail-Closed Circuit Breaker**

                        \+----------------------------+  
                        |  API Gateway Middleware    |  
                        \+-------------+--------------+  
                                      |  
                                Execute Rate Check  
                                      |  
                         \+------------v------------+  
                         | Redis Circuit Breaker   |  
                         \+------------+------------+  
                                      |  
               \+----------------------+----------------------+  
               | (Normal State)                              | (Circuit OPEN / Redis Down)  
               v                                             v  
    \+--------------------+                        \+--------------------+  
    | Execute Lua Script |                        | Check System Policy|  
    \+--------------------+                        \+---------+----------+  
                                                            |  
                                           \+----------------+----------------+  
                                           | (Default: Fail-Open)            | (Strict: Fail-Closed)  
                                           v                                 v  
                                \+--------------------+            \+--------------------+  
                                | Forward Request    |            | Reject HTTP 429    |  
                                | Log Degraded Metric|            | "Limiter Unavailable"|  
                                \+--------------------+            \+--------------------+

> * **Fail-Open (Default):** If Redis times out (![][image24]) or errors out, bypass rate limiting, increment a metric (rate\_limiter.fallback.open), and pass the request directly to upstream services. Protects user availability during cache infrastructure issues.  
> * **Fail-Closed:** Used strictly for sensitive financial, authorization, or heavy compute endpoints (e.g., AI model inference execution, card processing).

### **2\. Shadow Rate Limiting (Dry-Run Mode)**

When rolling out new rate limits for enterprise clients:

> * The Rate Limiter executes logic and logs rate\_limit.shadow\_exceeded.  
> * The Gateway **does not block** the request (returns HTTP 200).  
> * Generates analytics reports showing impacted clients before enforcing hard HTTP 429 drops.

### **3\. Client Graceful Backoff Handling**

Rate limit responses must communicate clear backoff guidance to prevent client retry storms:  
HTTP/1.1 429 Too Many Requests  
Content-Type: application/json  
Retry-After: 12  
RateLimit-Limit: 1000  
RateLimit-Remaining: 0  
RateLimit-Reset: 1735689612  
X-RateLimit-Policy: 1000;w=60

{  
  "error": {  
    "code": "TOO\_MANY\_REQUESTS",  
    "message": "API rate limit exceeded for tier 'PRO'. Retry in 12 seconds.",  
    "retry\_after\_seconds": 12  
  }  
}

## **8\. Summary Checklist for Interviews**

> 1. **Distinguish from Single-Node Limiter:** Immediately state that a distributed rate limiter solves multi-datacenter latency, atomic synchronization across nodes, and high-throughput Gateway routing.  
> 2. **Explain Gateway Placement:** Recommend in-process API Gateway middleware or sidecars (Envoy) over separate remote RPC limiter calls to avoid adding network hop latency.  
> 3. **Address Redis Scale:** Mention Redis Cluster hash tags {tenant\_id} to guarantee single-shard multi-key atomic Lua script execution.  
> 4. **Discuss Local Batching:** Explain trade-offs of local RAM counters with async Redis flushes to achieve sub-millisecond processing times at extreme scale (![][image13] QPS).  
> 5. **Detail Resiliency:** Cover Circuit Breakers (Fail-Open vs. Fail-Closed), Dry-Run Shadow Modes, and IETF standardized HTTP headers.

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFcAAAAZCAYAAABEmrJwAAAEJklEQVR4Xu2YeahVVRTGl0OOiUOWOaDkhFqhJkqa0gMp7R8VBGeRoj/KEHECBcmn4oDiX4koCjlUaCLiiILwHmZmVhaKoSk4BVrOU4jk8H2uvc/Zd+N+d7+OOXF+8MHZ31l333vW2cPaVyQnJycn53HTBpoMdYRqQS2hcdBqNwhUg0qhX6Hvoe1QezfA0AUqg/ZAB6BJUJWCiDiGQj9B30E/QP0Lbz+gMfSVaNzP0DKoXkGEEtPX/0Jf6J6nf6D33CCwCPoNetG0P4HOQi8nEfpiLkGjTbsR9Ds0PYmIYwB0U9KX1xW6Dr2bROjL3g+tEH15bH8N7XJiSExfIWr4RmUpgS5AJ6E/oC+hds590gK6DQ13PD4QkzvH8ZZAR5w24Uvgw9X3/IrgC+EodFkrOmMsQ0QHQjPH62A8d2DE9BWCszMTfaCVvunxmeiPftPzy0V/PGGy/4I2JHeVEtHPMhkxvC4az6XJpdT4TUx7PXQxuatw9N4Rfckktq8Q5b5RWXpL8eRy6vHHtPL8TdBdqLbo6GYMR74LpyH9eZ4fYpRo/BjPn2D8fqZ9HDqR3k64Krqukti+Quz2jcryDrRZdOpwvTosugm5bBP9MU09n6OHfmuou7n2p6AdPf4GGWKKaLy7BBE7ez4ybS41R9PbCeeh0+Y6tq8Q3JQz0RM6J1otECbwb9GpYykT/TGvOh5ZZ/zOohsEr5cWRGi/9Dd6fogZovHDPP9T4483bc4Yf30nXJoum+vYvkJkTm5d0ZHnsgq6JWkyy6V4ckvMddbklkrxhHB953Wx5JZK8b4qInNyH8Zs0S8fYdqhZeFb47eV8LLQyfisR2MITeWxxv/YtEPLAmfdn+Y6tq9ponWyL5Zsvket0Y8Vh4X1L6I7reVz0S/n4YIwYWy/lkQo3NDoc0Nj4nnNUe9iN7T5nh+CiWD8h55vNyF7AGBiT6W3E7ih7TPXsX2FyDRymdB/oWuiCbIsEP3ykabNWpXtbkmEwlrRnZpcu7c4bcKak5/1p2YIW6v6myrrafp2aWKtypHl8oJojF2aYvsKkSm5hEfUHp63A7oBvWTaLNT5EmyyCR+Eh4+5jsf68pjTJhNFT3wNHG+Q6DodgrXzcs9jRbPXadtDRHPHe8t47zteTF8hMid3ILRV0ocfLFqI2/XIwuMv/1ewcVNFT2gNkwitda9IWlfyaHxGdE2zcPQzAdx0ajm+C4+snN5vmHYv0RMia3JLVUmPv7yuLvocO50YEtNXiMzJJZyyB0UTwQQywT5cQmZBh0T/BOGD+Gsw4egpF31w9uWfjl4RLf45pSsavfxNnFU/io4y/gfiw5n1jeh/HtRiqE5BhBLT18N4JMl9EiyUtLZ+Wnlmk8tK47/8Ffk4eds3ngU+gGb6Zs6j4Quopm/m5OTkPMfcB6EQI9/3japDAAAAAElFTkSuQmCC>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAD4AAAAZCAYAAABpaJ3KAAACU0lEQVR4Xu2WzUtWQRTGT1baF0VKFELLdOGyxMqVuxZFUYv0Xwj8KgtX1aJW0kJwp7kQXQQStCiIatHXplBblBJCGZgRtNaIIJ+nM2PnvXVj7n3votfmgR/Xc+ZceZ+ZMzNXJCoqKqp87QNbksn1qg2gHnSDL+BQ6XBlqRp0gJrkwB+0AGbBFPghFWp8K+gEL0VXkKsZqn6pQOPbwHkwA3pFJyCr8hrPMrmFiYb7RA33SD7DXlmMT4BP4BtoBYPgDvgIhsFm0YW4JbqNboOdP99U1YKbou/cd8+HZjxV3vC0aGsXcRJnMb4fDIjW8zc0uvwxl3sOzrhcHVgB111MjYLLJj4BXpv4N3FF/QrTcMjhFaosxikaY/1Vk9vrco9MjnoLHph4DgyZmGJXpOoIWAKXpJhVtvLGm5MDKTolWs/V8uLqMsdusGK7PzHxuGjdBzAGzpqxVLHNL4JXoEuKmwBvvCU5kCIaZj3b22u3y10zOYpt/NTEu0TNcwuwnoyY8b9qu/yaAF5d5RxslDd+ODmQouMSbvyNlBo/7Z7cqkfBPdH3mtYqAsQOuCDln+zeOLdTiHyrhxp/ZuL34ICJ+cHF1Q+d9BLRMI3zCyzPXc5Tlj+6LTmQonbR+pMmt8flbpgcNQ9emHhBdG9XubgBfAY7fEEecc+fEz1MQszzHuUh8130R38F78AVW5TQJFgWreeT9zU7ht/6zPF/cVU5ibzvmSOL4CB47Op5d98VPfHZ8v+8OLl+tfhkzHbd6HL8mmNuk+jHjM/xb18TFRUVFfXfaRVz/4K68Qhj2gAAAABJRU5ErkJggg==>

[image3]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEoAAAAZCAYAAACWyrgoAAAD2klEQVR4Xu2XaahNURTH/8bMU8bIQ4YkGQpRJPFBwgeRpDzzHD4gEo96+SBTGcockZLILEMyyxAZyvgyphBliBLW/62979t3u9dbD584v/rX3euss846+6y99r5AQkJCwl+lpmij6LhoTHQtpI9oYmz8FW1FR0W3RfdFU9MvF1JGNE90Q3RPdESUk+aRnVqizdD4j0RrRBXTPOzxLbmegMZiTE4WY3URlXLXK4umi56J6jlbsTDAJ9FwN64veioam/LQB+wWXRVVdzYmwkQreacscJLot05UWlROdFi0PfCxxrfk2lH03V0jXUX7RYtFB6CTvFf0QDTa+Zi4JXoR2fJFr6AvRQZDHz4+5aEV8VU0I7BlYjX03laBjSVPWwc3tsa35JoLjcVqItVEh9xvDyecVecrrFgaQ4PyS4bwC9Hey403uXH/lIfyXHQ6ssVwqfHeqoGthbMtcmNLfGuufszqJZwoVrCHE3oZ6R+uWNpDg16K7COcfaYbs1Q57pvyUApEHyNbzDvovWFPynG2g25siW/NtZsb13VjLr0V7jeZC13WJaIhNOi1yM5GR/tKN17vxgNSHoqfBO4y2WCfoQ+/rMe/NBs3scS35srldAE6cVx+7EncAAgr+QqKlmmJYCnH634X9OEb3JhLguNxKQ+gjbNRjQJ7zFKoT8vANtnZ2FCJNb4lV1IbulmcEY0M7MegFfZbdILuJMPcuIfoLvThbMQeJsS1zV2JX4SJvHZ+dQK/GPqzqtZC+wa341PQ+7jFeyzxrblmIle0KhjzfMWGzv7I44KJztCGx8a5TDQB+vBwLZcXLYS+DHtLd9Fj0WcU7TDZaCDaIroo2gm9l/F5xvFY41tyjeFEX0fRhjIEWp0VRENFy529xMyGPrxffCGCX5cvVlK4PTP+kvhChCW+JddtooHBmJPEpu7hEvW7ZFYGQb9yeLDbCm2kfqfizNOHX8LTDJrgnMCWidaifdCe4xkFvdf3C2t8S64xvaHL2sMJ+SKaFNi4zH/VZwvZA02IJU3YI96KFqQ8gHZQn/DgNl/0Bnry9pSFlrI/FZNp0HtnBbaT0D7lsca35BrCD8CK5NL3cBl/Q/pE7YBhovJEd6BBa0CP+WeRvoVWEb2HnlkIy/wDft7Op0BfZHdg6wm9lxXFJNmHXoqaBj7W+HkoPteQfGT+U8wYYU87B8PSY8fnGn4iegjdzjP9f2Py/AtRIDoPnYAYno65DMLqIVw+vI/iJDZJu6pY4ltzJfwwPENl+pvCybsJjfdHzfxfgB+keWwMYPWziXPiWdH/Lf4okJCQkJCQAPwAf4of4wkC9+cAAAAASUVORK5CYII=>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACoAAAAZCAYAAABHLbxYAAACeUlEQVR4Xu2WS4jOURjGH7dcUi6lhkQmlxAG2diYjRUrC5GwUiQbNoiSctmwkigSkVvSjPtqRhkLhCIplDI1SMPGbVyfp/f9f/N+x/x936hJ8n/q13fOc873nffc3vMBhQr9mxqbGq4+ZBu5R1rIZTIxdnDVkSZyg9wlG0gvb5tENpO9ZJV73dIgMpc0kotJW6Y95D4Z7PXVpI2MKPUAxpB2stzrw8kjssXrmsQB8oMcd69qrSGvySXyFV0HOpp0kKXB0yop0B3B208eh7qkCb0nQ4L3Bn8QaNQndB3oWtgqTEv8ZtiKSQr8FTlXajXVw767OHiaYI8Eegg2WHp+G8h3MhC26upzpKwHMNP9XcFrRQ8FqmOhwUYm/ln3a8kcLx8s6wFMdf9Y8GKgK2HtGVuzTr9TXqBNsB+pSfzT7s8g87ysyxI12f3zwVOgJ7w8gHwgh8mEUo8Kygu0GZUDrfdydwJVyjtF1oe2qqRAtc2p8rb+jPvjkb/1U9yPZ1KBapInycPgVy0FeiU1YYNrsHGJr8skX5dJk1D5aFmPzsu0O3gK9As6d2pFaKtKCvRqasJyoX5wduLrhYp58yW5EOrSfNh3lwRPgWrLldJuwvL4sNBeUQr0WmpSo2CPwbLg9YMl7p3BU8J/EuqSzp8uy9DgaUL7vDwdtrrpkclVX/KZXE8bXHpC9c5nA26EJe64Esql72ApR9Lz+oJsKvWwVdQzGwPTcVE+Xhi8X7SAPCNvYVskNOOnKA9CN3Q7eUBuw7JDemalWbCzdws2sXWhbRHs9dIY38hz2P+Dj+4p2DtZ578pHRftnKSV7U96+2f2D0vlQoUK/df6CU3Do6nhPvN4AAAAAElFTkSuQmCC>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAAZCAYAAACVfbYAAAACbklEQVR4Xu2WO2gUURSGj8YHUQsFg1EEowSbIBaxCNpZ2Nj4aBSx0kLR1Gp3EXwVwToQELFSCzH4xMJV1EZBURALtbBRRBBUxEd8/D/n3uyZwwybWZdlI/PDBzP/mdk9/967916RSpUqdYJWeCOqCwTwGNwH18BqUz8IPoE/kRemlqdTUn/2K7ieLbdO88B6MA6uuFrSCHgCFsT7feAt6Jl8QsWm34g2vc7VkmaKhuEzr+N9I83xxlS0H7wHV8GE5IdbDn6AncabIRrumPGoAE6INn46W5rURnBIpjbCSZwp/6Rvkh/ugGgja5xfA8+dF8AW8Eo0PKez1xjok3Lhat4oq6JwbIaN+P/jZfAbdBsviIbjiPKdTaZGzZX6KJQJd9cbZVUUjlOWjSx1/sXorzJeEA03EGtnTY3aDobjdZlw97xRVkXhbos20uv889Ffa7wgGo56Cj6LLlhJF8CSeN0R4WrSXLgjovW0EC2U7Oe3PRynoFfRtOQo0O83XpB6uD7Regq0F+yJ11ReOP4gj3LgDPAeOaevNRbD5W2mo6KNrHQ+FxT6fkHZau4fgJ9gMbgJFplaXrgitWTkbnhTdMNmI4PO50nFNxfANnPPxYPvcu+7ZHyq7eH463otE93gdxlvNvgAjhuPCqIrYhIXD777C+wwPtW2cLPAd3DHF6J4/OK5kosCdVh0k7bTjKsip/VJyR6pboEvYL7xOJUZjscvnnYaqalwm0VPEx9Fv4y8Ay8l2zhPGkfBM/BQdJGw/0GeYjg66TN4GN4Qa7vBmXhN8ftYT8/ywJ23Sls1FW666L8ON+SNSpUqVWqL/gJaJq5tGTbfqQAAAABJRU5ErkJggg==>

[image6]: <data:image/png;base64,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>

[image7]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAB8AAAAZCAYAAADJ9/UkAAAB5klEQVR4Xu2VO0heQRCFR9QiEvABQpQQUURIRHxhY+PfpEovioitImmSJoKFBHw0aUVBECVNFBEf8VGpkDQKKggiaKoUiSJqo5ggieew63V31ouFYHUPfHD37NyZvfvvzi+SKJFRkTas0kEP2ALfwQIocwOsqsAK+AY2wXuQ5kUoZYF6MAvm1dyNPoFt8NSO28EvkB9FiLwAJ6DVjvPALuiOIpQ6wBH4Cq7k7uLPwV/Q7Hj8GhbvdbxBsOeMKS7yHGQrP9Cl3F28E/wHFcpfFfNlFBdzCKaiWaOUmHcblR8orviImAT6PMyAf+CJmN1hzKgXIVJt/X7lB4orzp+ECQqUP2n9ElBnn4e9CJFy648rP1BccZ5eJnim/C/WrwQN9nnIixB5af1p5QeKK74q9xdP2ecHFecWa8Vt+4T1SyV+219Z/7PyA7H4ojbFJGSCYuXzwNHngePC+DzmRdweuAHlB2LxJW2KuatMUKt8djr3Xv8Gc86Yei3m3SblB2LxZW1ChWIaUIvjZYJj0Od4bDL7zph6By5AjvI9ZYA/YE1PWLG9sq/fJPkgpsPlRhHmrp+BNjtm6/0JuqIIpTfgBzgVsz2E23cgfmL+sXwEO2BDzK3QZ4CqEXM71sUs9q03myhRosfUNTqDdp1CwGKdAAAAAElFTkSuQmCC>

[image8]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFcAAAAZCAYAAABEmrJwAAAEK0lEQVR4Xu2YW6iUVRTHV1lZdlEJKSO7WVpCFESKWabdCCqSJKiEIOxBCB+sHnrIOGhFFyMECaSwDCq6EBTdwLRBi7LULlZkQZZWRuiDXaXS+v9ae5+zZzlnzsycHF++H/yZ2f/Z83171t577fWNWUVFRUVFtxkr3S6dIR0qnSDNlZ4sO4khUo/0ofSO9Jo0ruywDzhS2iStKbxrpQXSI9LpyZskzZcWSzOSl/0d0j2F11Uulv4J+l26tOwkHpI+ko5I7TnSNmlUb4//n5Ok3dKv5pMLs6X3zMc5LXkXSc8lryd5cGPyXi+8rjJN2i59I30pPS6dVnwOx0t/StcX3gHmwd3Xq2KqdHbwrrL64AKrPAb3QOkaaXThdZULpCeiGbjFfOBnBr8mfR68bnCF7R3cw5PXU3j7nfNt4OA+Zj7wE4P/krRHOiz4jWClt8sw8zPgnOBfbnsHl/MiBne4+ZmSc3MndDLuXqZIL0tLpTelz6Tb6nqYvWo+8Li9nk/+KcHPPGWeOkgp3IcDhwn5XnpUOli6VXrWfAe8KB313zedb63vHChpJbgTpD+SV0tehnMjnyHvmn/ODs70N+4t0hJrI+CTpR/NqwUggD9Z/Qp4y3yQxxYeEBT8s4KfGSM9aN5ngzQ++Tk4VB0zk3e0eTBiDn/GOgsuHGI+QbXCG2p+ILKYyMlAAH8xvy4MNO4rU3tAyFVx5S2XdllfMGvWWXCB4MUffUzyVhYeUHatCN4i6zy4sM7qg3uneSpjMkueNt9RBB+ajfuuwmubheYXuSG1+0sLufw5Nfgl1J304YTP8MPwWB0lpIbVwXvABhfc960+uNzjh6KdIWB8/5LUbjbuBYXXFAr09dZXR0K+EQ8XwBaifXJvD4c8hN/sQMtlU95yMDJ5dxcefGr1Dwxwnw0uuKSAWtHeaZ4qIneYf/+m1G42bhbfgBDQv6WfrT5AebXMSu05qR1PbXLmF8GLkJ/6G2QMLodpDO79NrjgrrX64HIP6voIub4cZ7NxtxRcIGFPDN4b5k9FOS8dZz4JOdjASc8g7y28RuTt1WiQjYL7dvAaBbedOjcGly1Nv/hkSaXC72GSoJ1x98vV0ivSiNQmkfPIeXNvD4fShf8Vcj+2EeUKN2zGdeYD4j4Zfhge1yz5yjxHljxs3vegwuNaeJcVHjUtXpxsFk85YZR6H5s/ieZrXmheqeTKBZqNm0O2ZbjQJ9JW8wCWN8mQQpj1jdIH5hMSc3DkBfP/KRgQr1QXTAorBI/dsFmabj5ReOg76dz0GX3wOIRYRVzjt+Sxu5ZJ88z/oMH7yzxVnWd++uNRHXxtfQuBVyaNHI9Wmf8/kWl13PsVtliuJXmlTe2ZD0+KcTxWEGkme7ynD5/lgp0+iFKpvCbtVq5Jv1aL/1bHXVFRUVFRUVHRIf8C5JYvTbMjMecAAAAASUVORK5CYII=>

[image9]: <data:image/png;base64,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>

[image10]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAD8AAAAWCAYAAAB3/EQhAAAC+0lEQVR4Xu2XWaiNURTHl3ko8xTCfaCEiEcPnGQqIQlPvEny5E3Jg6kkpAwRj0h5MGROwgshJEKmDMmYjJHx/79rfeess+53ON+57i2cf/1yvv/e59prf2uvvY5IVVVV9b9qMrgK3tu/c0GTohmVqV80TF3BDnABXARbQbuiGY2kseAS6AHag03gB1jhJ2VQWzASHAAHwxjVDJwH20U3mM87wQk/qbF0Fox2z1zMXfAd9HF+OZoPnoND4KukBz9TdHN7OW+geeOc1+BioN/APdDB+dtEFzPPeVn1SdKD3wNeBS9Zx+bgN6iagteigfZ3/lrzFjovq0oFfwfcjyb0RjQLfyeu+Y9puNRNt+NS/zQsFfwHcCua0AvwMJqmFuAmeAmeiR4TFkyu8wlYIFqv1oO9osd2Ze03CxpiY/vBqeKhgvqCL+C61G+XSwXPWsJAohgUszBNLIwM+CT4KBoAg6VWia73KBhg3iSp+/J4tEe551TtAm/B0DiQUWnBMwguKmvwiTaIfj/nvFnmLXFeT/MW2zNvMj7PyM9I0WzRtMw5b47oNfQr9uVnF8TgWfWjSqU9b4nH0QxiWjMI3xNMN49vO1F385bZMwvqA/Mug43m5zVM9EyNiQMVisEfiaZo4FxIFAveuWgGJYW4tfOmmcd+JRGbKHrLnTcYnBE9dhzLqzO4ASY6LyeaUpWKwfMcRu0G74LHgsYFbQl+1BopL/hu5iXBs/GaYJ87gin2uTYlDoumj9dSMDV4WcTgj0VTCk1Ob+eNMG+889KUpH25wSddag14JCkt+2rRc3jNYJXnXfwZDHLzsqi56PdPxwHRGyRpb/mZc1kY0zYqipnBoHxDxiJGj79PEnFj6TE2qsae+ZslrzZmpsGz4Xe4HLHo8I5NGifyVHQzO7l5XURvlSsGCxBTs5RaijZG7AL5N9khsgHjvc0XR49XIH8jLJLC/88W+7Zom85rcp1oHWKm/1Xii0jSlkeVG+I9ZlEr8zlOcSzrC6yqqn9VPwE/7sW6EkRCfgAAAABJRU5ErkJggg==>

[image11]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEUAAAAWCAYAAACWl1FwAAAAnElEQVR4Xu2Wuw3CQBBEhwTzqcil0AKSDcaGAkkRhiqogxlOCN2ZgBBp50kv2uxp7wMYY4wx/86cbmhVDiKypA290B2d5eNYrOiB3miHFCcsijEgxdjDMV4xRqTjssjHsdAmvDdDMXyRkpo+6AnBt6NER+dI77SF42Ss8Ymj5zf0JVuizenhF+griqEoV/ivMkF3zJae4TDGGPMzTwrbExDw4RhZAAAAAElFTkSuQmCC>

[image12]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADcAAAAWCAYAAABkKwTVAAAAmUlEQVR4Xu2VSw6CQBAFnxsFORFH8QokfkEPyJYonIJz8F4mxtBb2UynK6lVryo9NEAQBEGwPXt6ogc7yJmSnulAr3S3HufJkT7oSO9IkdmjqA4p6gZnUR+kZ1isx3mizXw3pShXB6OmM33BybYsepJPOtELnEZW+EXq7Ls4JhZtsoWzi2lRlOLecPSvs+gbbGgPp4FBEPzHAk0WExDnOTuKAAAAAElFTkSuQmCC>

[image13]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAC0AAAAZCAYAAACl8achAAABuUlEQVR4Xu2WyytEYRjGX6GkLNyWKMVSKSvCLCRlZ8NKs0P+AQtydmJjY0v2diKUjZKFLFxSEkvXXDcuuT5P33fqO28z5pIZ5Pzq15zzPl/NM6e+74xISMj/oEoPwAl8hh/W7mAcoBQ+iFn3Bu9ga2DFN1EIG+E8XFCZD9ecwheJv4b0wx0xpaPBKC75epCIAXgJF+GrfF1oGy6JKV6mMh/+8DExpXtUFotmOKSHqfAkiUv3iik0qDJSCaehJ8mXboPDepgKyZQugo9wQ2WET6xdUivN9RkvTebElKp2MrIKcyW10h2SpdJdYkqNOFkdnLLXnvzC0gXwHh442ThssteeZLk0T5F4+KXJrJhiDTAHrttP4tnMLV0ON+GW8lDMe0DPKU+WhLA0j7R48Pz14QZisUkYgRNO5tksa096WQ8ddp1rbrgLeAZnYL2TeZLl0it66LCn7rnxWG5fzT07z3jpPDH/L9Z0YInAa1jhzLjxWG7UmRFuSs6jah6LtEp3wmN4K+aL6Dk8gsV2De/97F3Mq5pw4/Ep19r7Pnhj13AtX/dXsMXmsUir9E/zJ0uXwBo9DAkJ+cV8Ao46gTru7DhCAAAAAElFTkSuQmCC>

[image14]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAD0AAAAZCAYAAACCXybJAAADRUlEQVR4Xu2XWahNYRTH/+Z5noe4CS8eeDAlUoYyJCXjk5QHhIRQJMqDKA9KIaUMDwpFZpExUuYxQ26KDGXKPP//1t7nrv3Z173n3tN9uPf869c539rrfHuvb69vre8AeeWVV1VQ59DgVJssJzfIZbKD1Et4lKxmZAu5BpvnCOmZ8DCNI1dgfpfIhOTlVB0gM0NjcapPBpD9sB+mqQ45RPaShqQR7KEWe6dS6DSZHn2vQc6Sj6R7xgMYRY6T5tG4A7mD/wc+mvwms8MLadLKvCQHyQ8UH/QK8oo0iMZ6MN1kW+xQChXAflPobIsi2zpnOw97CV5TyIXAFqsWuYssgvb6gvSgG5NPZHNgW0/6OltJakHekVvOtgT2sGuc7SmZ48bSSHIzsMVaQLYix0FPhE04I7xQBjUhdd14N2zuQc52jnwl80n1yLYTVk9CtYZlRj/kOGilXhz0LnKKXCUjnE9ZpH34Hcm3LGnr/ITd8yTZAFscpXEoZd9w0hs5DlqrrAm1b9pEtvHkG+kfO2WhweQ6+UC2Iz2YabB7Ci2AxqF6wQqrlPOg98AmXO1sSrvX5IyzZSu1uxOw1tXO2buRe2QhrLrHwc9zPtIx0jX6Xq6gVcVDbYJNODmwP4C9BRW1smoIbG61Q0lngfso6rda3KWwbaB97jNtbfRdKlfQh0MjtRI24ZjArrche6fAXpzU7sYieaApgM3xC7Z4OpSohaqHe6lHy0+fKoQXkVzscgWtE1KoYbAJVcW9HsLegA43pdFG2DxqdbGUynH6qqXNghXJND0nk0gf8jYax2iraY730ThO+xKloI+GRljK6SbLApsKkU5xsfQGppK2zuYVB+1PceoAsqmwSWpdOhO0zHiYdArUM3QM7LGU7lm/6ZqwPaNjYpp0ANChIU5lnaT0EF0yHuajG6ctnKRq+4IMJdVgi6Tj5mcy0PmpmKpVtY/Grcg+sirj8a9Ub3TvueGFNKlXPiJvUJRmSg+lrv4ceKl6qsgoeFXdHsnLf4uS5nkW2L3U4rQoT8hjWDBaDC/teXWKQpjPbVjap0mLrufX+V3PrizR2L+MClFaB6jUaors/oRUCiktleZVRvozEZ6j88orr4rRH6ttzopuchhSAAAAAElFTkSuQmCC>

[image15]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFwAAAAZCAYAAAC8ekmHAAAEhElEQVR4Xu2YaahVVRTHV6PNGTbb8CqVQhuoEKWMB40UFRWW1of6UBBEHxo+FA1ImkikSEUoBGlkNBBRNKrZIwmjbMYoG2yiORq1sqz+v9be9+273rv3nlsgrzg/+MPb/7PfPeesvfdaex+zmpqampr/OgdIV0oHSVtJ+0iXSneVncRm0jTpFek56XFpTNnhH9ITjcRJ0gXS3ubPxfPNkS4v+sDO0t3Si9JKab60fVOPIcax0p9B66Tjy05itvSqtF1qXyx9Ju3S6FGdLaQDzQP4XbiWmW4Dn+t98wHIMAlekO6QNkntRdLSos+Qo1f6WvpAWi3dKY0ursNe0nppauHxggT8xsKrwsHSN9IK6SPpp+bLDaZJH0qfSK+Z32fHsoM423wg9iw8BhIvTpghwyRpQTQDl5i/BMEq6ZPeDF43PGmtA36deUppxwPmg1fCLN8g3R78IcPR1jngLFkCvm/wH5b+kLYOflXaBfxa6xzwd6U10RTfm6+gTmwajY3BUdIj5sWG3LdKuqKph9lj5gHfI/jMMPz9g1+VdgG/RrpZelBabp6rT27qYbZWejt48JV5uhoM6sdb5mn0C/MURNFdLH1qvpp3kOZKD0nv2cC0OS5dY8L1mT8jz1qJidLn5rsAIKhfmufQzDPmgd298OC+5B8a/Kq0C/jV0rPWn7ePk36z5tzM6iJ4EQL5bTQT1B6CvMx8c0DQCDDMMr8Hz5Xr2Ck2sCZQvI8p2gT7tqLdlm1t4AxdKP1i/QHus40f8JHSTsGjiLJTAgLHvbsNeOZW8//vLbxzkkf9yDAB8VhxsFtqT2708Np2Q9HumrwlOze1W6WU+5M/yjwdddKZ/m8NCDhpoSqkFu6XdyWtUgorlN1NO0gZ/Fa5Zz8reczqzK7JywGlKDPweJxJmNkT0rVK8BIvmf9Q5nrzH+RABOR32vs1ejgsR/x/UzR/jqb57GbLeUvwSQPc78jUJti8fISi+Xw0A5wr+C0OVZkzkkf6ynCwwmMSZsaapztSGtd+l84vrreEINP5B2sO2k3mP3ReanPIoX1Eo4fDiXOwJV0VAk7qivSa329J8Cmc+AwI3Cv92H/5byiK9JkX/Ah5t0rAOdiVAd9GOjH9PVw6zXzgqYOkuY68LI0PXs6tI1KbJczA5AEAXoxKP7PwuoX7/BpN82VMYeKFMluaT4xyu5cPPnkA4PDknVB4g5FTStWAz0jtHuljaw4uBZQCXCngp0uPWv/Lkcc4OFzY6OGwBMlZud9V5ss+FrZueNp8V8DgRTj2kzdZhZub35/ZfFjRh310PtrzN/14l6eKPq1gBRDI8vRKIcQ7tfAYTDxWPfSk9kW5Q/qbb0uVmSK9bj5yBJWgR3hxAvCG+YciXizm9CqQEzmwsOflwRHfU/D4YJXhfswqPjfQl9VwSHE9wyq8x3z3gihiLPtWsFLWmE8q7s1J9TLzfTVFGI/Zush8UrHbwWOFv2P+LYdawoR4wjzQnEfKVVYTII3k5c/AMgilx2oZlvy8meBamX5qampqampqav4n/AXF+B8KiTgDpwAAAABJRU5ErkJggg==>

[image16]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAA4AAAAaCAYAAACHD21cAAAAtklEQVR4XmNgGAW0B45AfBmIPwHxfyh9HYg3ISvCB3YyQDTqoUvgA6xA/AWIH6NLEAI2DBDb5qJLEAKNDBCNkegShMAxIP4HxGLoEvgAPxD/AeLz6BKEQCADxJld6BJQUAHEMuiCIDCdAaLRDV0CCPiA+DC6IAzcBeKfQMyFLgEEU4A4H10QBNQZILYdQBOXAOJpQPwDiIWQJWyB+AIQv2eAaATRIP4lIL4PxH+h4qthGkbB8AEALIIlVs8MCuUAAAAASUVORK5CYII=>

[image17]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABMAAAAaCAYAAABVX2cEAAABDElEQVR4XmNgGAXDFzgD8S0gfg/E/4H4IKo0GJwF4n8MEPlvQDwbVRoTbAHiewwQDZZociCQDcTLgJgJXQIdsALxGSCOYIAYthZVGgymMEB8QRDYAPFkIGYG4vtA/BeIVVBUQCxjRxPDChqB2A/KzmWAuG4aQppBCoi3I/HxggNAzAtlcwHxGwZIQItAxeKBuAjKxgv4GCCGIYMmBojr6qD85UCsi5DGDfyBuB5NTBSIvwPxKyDmBuLLqNK4ASiWrNEFgWA6A8R1c4B4EZocTnAOiFnQBRkgsQmKVZCBMWhyWIEdEJ9GF0QCoPQGMkwCXQIZuAHxAwZEFnkCxPbICqDAnAGSlUbBKBhQAADIFjDhxd8YOAAAAABJRU5ErkJggg==>

[image18]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAA8AAAAaCAYAAABozQZiAAAA1ElEQVR4Xu2SzwoBURTGz0L+rElZkZKnsJs8gVIewWvYyBNYeBDFwsaSoVgoNlbKykL+Fb7TYTodybWxMb/6LeY78907c7tEIb+nCm9wDxdwBnePbAvncAlP8AxLUhO6sAFjKuuTlIsqy8ILTD+DFBwGYyEOD3BtcmaqH+qwpgPgkezaMTkv2tNBHkZ1AJokZT4LTQQWTPbCCF5JfukrkiTFsR24UCH55JYduNAmKZftwIUVPMKEHXyCT5J3HZj8LRnowwnckJT5GvKV5DwXvBnyl9wBmHIpv8bCEcoAAAAASUVORK5CYII=>

[image19]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABYAAAAaCAYAAACzdqxAAAABRElEQVR4Xu2TvyuFURjHHxKDRGRRN5PBIKIYFMVAKYtVGUxmFhaLwb9gs5kokuQfYLkGP6JMWBT5MViUH5+n56jjuXLu1V1uvZ/69PZ+n3uee857zhHJyEgxgKf4jJ94iydBze9wB7u+B5TKpljjNpfn8AkfsdXVklThPR77QuBQ7E+HfSFFt9jAFV+ADnzDC6x1tSTzYo0Ho0xXMY7XuCeFn6go9sVmtYvbwSN8wLnodyVRh69iTT2j+I5rLu/HK5cVMCL2GRZ8IaAbqvXOKGvBoej9V1bFBvb5QuBGrN7jCyl0RnpOq30BJsWa5sU2U13GA0nMWHf6A7dcXoPT+IKX2B7yMbGGGzgbsh/04rnYTHVG+jyL1NOgzyWsD2OUJmwQu4XNUV4WZsRW2Ci2srKhl2UKF+UfN/Ev9BSt44TLMyqZL0ekQhZ0yTnrAAAAAElFTkSuQmCC>

[image20]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAAzCAYAAAAq0lQuAAACWUlEQVR4Xu3dT6tNURgG8C0GCsnATL4BQ5kpEwPlAyimBlJKigGtDAxEytBE5v7k34ABoUwYSKQUA0pJBqREinc553bXfUO39r7u6fj96unu99n7dqeru9dZp+sAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAmL+Dke+RH5Fn6R4AABPic+RdLgEAmBz1v2u7cgkAwGRYGXmaSwAAJsf2yOlcAgAwOZ5HVjTzlsiZZgYAYIEtz0VS96/N2Bh52MxZu7ADAGAgR3Ixtr8b7V2rC7bHzfXe9qHkaC4AAKbR+ciLyNfIk3Hqa8ml7UMDKrnooeQCAGBa7YvsaOZtkTvNPKSSix5KLgAAptXlbu5+sHOR3c08pJKLHkouAACm0eZutFfsSuR65H1k/ZwnhlVy0UPJBQDANLoX+Zi69pOaW5vrIZQ0178132QlFwAA0+hb5Frqfrc4yi5EHv0lf1Jy0UPJBQDANKqLs3reWVVfhdbXoofH8/HIm/H1UEoueii5AACYNi+70YKtHutRzz37ELnU3F8TOdnMQyi56KHkAgDgf7Mpsi6XPZVc9FByAQBAfyUXyavIzWauB/i+buZqSWRZ5FjqAQAYwP1xbucbYzu70WvaDeN5beTu7O1f6u/W3Eo9AAALbOaL4d92o0+vVme70VlxAABMgBPjn6sjnyKrIhdnbwMAsNgeNNenIgcie5oOAIBFVPeuHUrdfA7wBQDgH7jajRZnX1J/I80AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMD/7Ccl8F7P3UCVYgAAAABJRU5ErkJggg==>

[image21]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACYAAAAZCAYAAABdEVzWAAACtklEQVR4Xu2VWchNURTH/8isTBnK9KUoSXjAEy5viEIkiSd8JcWDpGSM8kB5ICFljGRI5iRkCFHGMvUZokxRhjwo/n9r73P22fc79/oeeDr/+tVda6979l57r702UKhQRU0mZ8he0iMa82pKdpJm8UCsAbCPPSBPyPzs8B81IUvJHfKYnCa9MhFAibwl7dzvz7BvdUxDMJhcIGsDX70aRr6TGc7uSl6R2UkE0IgcIrdIW+fTIpVEKx9EHSNbAlvJziMHyUlYMkdg/2sRxNWr++RN5FtD3sO2XJpCfpG5SQTQkvwkCwPfc7I6sDfAEg91nIyOfGXqCZtQOxFKuyW//8AOZ49PIkyvyaXIXhXY8cKmwb5VVYNgE16P/LOcf5Gzjzp7TBJhqiPfAvss2RzYOj5fX+3JXdIhHc5XN9iEtyP/Auff6Oxtzp6QRJhU3PJrUmkseensEjng/NJ2Mj2wq0rHGNeYilUT6mOSjlD2nCQC6O98onvg13FdhF2Wzs43ErZ7DdIQ2K302Ywgj2ATbvJBsMXehN1KXQr1qQ8urlMQF6s5LPkaZyuJfeQcGed8uRpKTsEKWQVbC5tQLcFLzXAlbHEnyHDygvyA9bg86TL4m6u4e2QqrF1cJV3c2F9pMWxh1TLSTmuheepHriBduEpCiTR29kSkF6xMekL2I9sod8EKW71KUnaKUaZevWGLXxL4Qqkpn4fdfC+dwLvA7oO0jsukTqwJdJySaugTWZ5EAANhMWEBLyMfkX/91QvXRT4da7iwvqiwsBXkIWxX9MapM19G2vWlNuQLrL9JOuKvKG8fXrqNN5DuuJd2PKzJSahwlK3Jblj/eUbWI3usXlqMnq86WNGWMqNZ7SGjYics+adkpvt9DfY2/xfpCdoaOwPVkMOwDpC34/9EaivqXYUKFWqofgOE5pCcWV9r/AAAAABJRU5ErkJggg==>

[image22]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAE4AAAAZCAYAAACfIRhSAAADG0lEQVR4Xu2XW6hNQRzGP/d7URRyOS4hheJJ8oIHlKJckzpPcr+TJ4l4EYUk5cnlAUkK8SAnJXIvhdweFF4oyp3wff4z58weZ689e+86tbV+9XX2fGv2mb2+NfOfWUBOTk5OTiW0obZS96hr1AVqWNghkbrY+N/ZTd2nurr2EuoN1auxR3HaUSOoPdT76FpN0p5aQHWIL0T0o77D+npawYLbEXjNMYp6R12nXlIfCy/XFp2oldQtajUshCyWU79hIYQ0UA8jL4uLqNHgOlPrYHVqLSzAFA7DghsY+WepX0j/P5UE1zo2WhIFtgEW2Bqk36jnPCy4PpF/yvmDI78YqcGNp55TH2BjzHB/b1KPqImwjeko7H8+peb8/WYTs2C/+xx1lbpEzSzokYEP7C5saXYsvJzMFVhAvSP/hPPHRH4xUoPT7x5LvYXVxX1oKic3qGfUGaqb83ZRX4L2ENh3fVs1XCeB2a5dFM0oP8MUWKniX4oGtGxwngfUZxSukIOwMTXrPNq05E1w7Xmwcep8B7KYmha0m0VT/TW1CZXPspBiS/Wk84dGfjEU3KfYzEDHnzuRtx82ZpfAm+u8Sa6to89P6hvsoW+nBrhrJdF03wgbfBWqC/AQ7IcNinxtDvJTa6aC05JKRaFpaYbshY3ZNvC0BOVNDjzVuCfOl3QkGh1cL4mejA9QR4/UmwzRYVeDj4t81Y3HkZeFgvsamxncRlpw2hjC4IZTI93n/tRS2EajFVI2moHrUdnO2hc29RcGnt4GVIB3Bp5uZj7+rYUeBaflk4oedjnBTXHteupY41VjC2z8ilFgCk7LoJyznF65FHp3194Me3Po0dgDWAG7gdOBF3KZ+gELPQUdPTRmyAHYGH7HFHqg8qa7dj2sloab1nFYza8a1bxlsDNOSnh6yd8G2+n0xqHzUVzzVJz1Lhr+wJ6w44M2K19v1Efe1KBfiHbMsP8r2Gx6AZv5vmapdqvOqm7KU1hHqEWwgLXra2PTA9ODT31gNYuWob9Jnd/0WZ4etj/P6UHqXTv09JZR7dErJycnJycnpyr+AM+vtClyDp7YAAAAAElFTkSuQmCC>

[image23]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADsAAAAZCAYAAACPQVaOAAADLklEQVR4Xu2WWchNURTHl5mMkUSGIpmSKWTKpcSL4UHyQDyYHngxZAhRClFkChkuESnzkAyZH8iUMpR4oEwPolBe8P9/a+/vrLO/e93p6xadf/3q7LX2PfesvdZee4skSpSoTOoFToHzYEjgs1oG+oXGcqgmWA6eg4fgEugTm6HqDa6B26LzFoAaxt8cfALDQEvwAWwGncycNmCH6Dvsb8um9WAjqOXGQ8F7iX9ke/AZTHVjBvZMdJG85oMXZrxU9L17wTlwERwFX0B3M69sagS+imbXahdYa8bMhg2EmgO+g6ZunAa3Kr0i48BiM6YWgdWBLatS4IxoqVSHOoPfoGdgZ7a3umeW20dwPHJXKCX620lufBjcrPRWDbYjeADqGVtOdQB7RPfW8MBXqBqCn6JlO9rZGoCXEr27rWhQ+93Yi/uadl8BbDosbS+W8QQzZhkXnSTuqTS4LKUFvU70ownL9SpYaPz9nY+lbdXD2Q+6cWvRfT1AtEE9AnWcbwrY7Z5LEkuRf3hFigua+5VZ8wEzy/xgL76T9p3GRnVz9pPG1lc0g/yWgc7WAjwBzfyk6lAX0X3DPyqkXMaCV6IN541oAD/AIOdPOVs+wWZSGkx0z8z0BtEjbImfUIrY1i+I7un6gS9UV/BNogbF1T8mGsRjZ8tWxvwf2g8FdquR4LQZc5sQios33vgKFj92leihPz3myawt4ERohLaLBsK9x73I5wOxGVGD4p7PJC40uy8bHMVyZjMc7MY8q3n+FiyedStFm8IMUDvuzipmcVNoFM04A2nlxrwNnY3cFRolOmdyYPdaA+aaMS8rnG8vFDfMc041Eb3FsORmS9T98tUKcFeqXt1GSPwSwdLjcWTFGxP3dqbGw4AYiL2ssKTDYO25nFW8+fBcYybZWOrG3XmLpcWmxDus39/cv0/BGD9JtBR5zZvmxizvt6JnaSguHI8vHk1WrJJfohmm+N9/LWN+EC/g90UzWWyQVu3AEfAOvAZ3RLMQisfKdXBPdJHnxbyRZor2jUxiM9vnnnM2KK7KLCm8XMslJoP342xJoH+b6IJyC/3zahwaEiVKlOi/0R/66aA1l+9C5QAAAABJRU5ErkJggg==>

[image24]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAD4AAAAZCAYAAABpaJ3KAAACoUlEQVR4Xu2XS6hNURjH/97yvN6lhIQbQxPPMFOIKAwNhJlyJ0K6AzIQUWYeSSQlopBXeU4QBt4UyiNlJFES/n/fWte31z3nOnsf6nbtX/3aZ3177bP32utb31kHKCkpKSnGajqXDqa96VR6gk7xnToi1+iPxNO0u+/UEblMH9PX9DpdRTv7Du2BWfQUnZHE6+ESHZUG2yMj6V56ns5MzhXhIuobeKc08K8ZQw/QC6jvBej6NfQsvUXP0MZMj9Ycpu/oVzqN7qIn6Ru6h3aja+lR+pAep/1+XWkMpPtg15wLR01ALsbSg7ALi7wA3XgHfq/rzfQtHd7SozUj6DZYIbxDx4f4nBC7QReH2CD6hW4JbbGfbnLt+fS+a+dCN9dM6AXkqQETkC1mo2EPv9PFKqGBqV+ziw0LMdUNzxNYZkUe0d2uLZQVdaGBKF1VA3om52qhC+zhn6YnEhbC+mm2IppdxZQNHqX7Vdc+BOv3CpatS925QjTAZkDptzxzpjLauHykS5L4d/opiaVowHp4pXdkQIhpuXiUxtovRPrDBq8loP5SBTs3+iKtmbt0Be2aPV2VZthNN7hYrxB75mKVmIfaB/4A2YEvCscesJ2iMlTXTWzp8QdUKTfSe7CNh6ppHpSuqqhK78hk2ENsdbFKxFSvdeDaHEVewIpyRLtEzb7u3SZ96HrYDGuvXXR7qaKmB4rrVEvlCmxN9o2dqrAMNsgFLjYkxLa7mFD23HTtl7C1HYvqOPoeNq6KqFg10duwGS46YM9QeoQ+h21btdb0h6UtjtHPsEHqqN/rdfRDiH2Dzeps2O99XMf6/kmwl6v++gXS/wJVfKV8VabTlcif0n8bTUCcLR3V1iTEJaPdnGKqNfFZFdNnv6xKSkpKSv4rfgJSeY2aHUofBAAAAABJRU5ErkJggg==>
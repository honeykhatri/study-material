# **Comprehensive System Design Interview Prep Guide**

This guide breaks down the 10 top system design interview topics featured in top-tier tech interviews. Each topic includes key architectural concepts, trade-offs, data structures, and edge cases commonly tested by interviewers.

## **Standard 4-Step Framework for System Design Interviews**

Before diving into specific questions, apply this 4-step framework to every system design interview:

> 1. **Clarify Requirements & Constraints (5–10 mins)**  
   * **Functional:** What are the top 2–3 user actions? What is *out of scope*?  
   * **Non-Functional:** Availability vs. Consistency (CAP theorem), Latency SLAs, Throughput (QPS), Data retention.  
   * **Back-of-the-envelope calculations:** Read/Write QPS, Bandwidth (ingress/egress), Storage requirements over 5 years.  
> 2. **High-Level Design & API/Data Model (10–15 mins)**  
   * Define API endpoints (REST/gRPC/WebSocket).  
   * Schema design (SQL vs. NoSQL) and primary data flows.  
   * Draw main components: Client → Load Balancer → API Gateway → Application Services → Cache/DB.  
> 3. **Deep Dive into Key Components & Bottlenecks (15–20 mins)**  
   * Solve specific core problems (e.g., race conditions, real-time messaging, distributed locks).  
   * Scaling strategy: Sharding keys, replication topologies, message brokers.  
> 4. **Reliability, Edge Cases & Wrap-Up (5 mins)**  
   * Single points of failure (SPOF), fallback strategies, monitoring/alerting, rate limiting, security.

## **Detailed Breakdown by Problem**

### **1\. Design a Rate Limiter**

*Controls the rate of traffic sent by a client or service to prevent resource exhaustion and Denial of Service (DoS).*

#### **Key Concepts & Algorithms**

> * **Token Bucket:**  
  * **How it works:** Tokens added to a bucket at a fixed rate. Requests consume a token. If the bucket is empty, drop/throttle request.  
  * **Pros/Cons:** Handles traffic bursts well; requires state tracking per user/IP.  
> * **Leaky Bucket:**  
  * **How it works:** Queue with fixed capacity. Requests leave at a constant smooth rate.  
  * **Pros/Cons:** Smooths out traffic; can cause request latency if queue fills up.  
> * **Sliding Window Log:**  
  * **How it works:** Keeps timestamps of requests in a Sorted Set (e.g., Redis ZSET). Removes entries older than window.  
  * **Pros/Cons:** Very accurate; high memory footprint.  
> * **Sliding Window Counter:**  
  * **How it works:** Combines fixed window counters from previous and current windows using weighted averages.  
  * **Pros/Cons:** Memory efficient, minimal accuracy error (\~0.05%).

#### **Architecture & Deep Dives**

> * **Storage:** Redis is ideal due to in-memory speeds and atomic operation primitives.  
> * **Race Conditions:** In a distributed setup, multiple concurrent requests can cause time-of-check to time-of-use (TOCTOU) bugs.  
  * *Solution:* Use Redis Lua scripts or atomic counters (INCRBY).  
> * **Interviewer Trap:** How to handle rate limiting across multiple geographically distributed data centers without global lock contention?  
  * *Answer:* Local rate limiting at the edge (CDN/API Gateway) with periodic sync to central store, or local counter fallback during cross-DC latency spikes.

### **2\. Design a Chat Application (e.g., WhatsApp / Slack)**

*Supports real-time 1:1 and group messaging, online/offline status, and typing indicators.*

#### **Key Concepts & Technologies**

> * **WebSockets vs. HTTP Long Polling:** WebSockets provide full-duplex, low-latency persistent TCP connections necessary for bi-directional updates.  
> * **Redis Pub/Sub vs. Message Queues:**  
  * **Redis Pub/Sub:** Great for ephemeral, real-time fanout (e.g., typing indicators, online status).  
  * **Kafka / RabbitMQ:** Essential for durable message delivery and event sourcing (e.g., chat history, offline messages).  
> * **Offline Message Delivery:**  
  * When User B is offline, push the message to a persistent store (NoSQL like Cassandra/HBase or DynamoDB) and trigger a Push Notification Gateway (APNs/FCM).  
  * When User B comes online, client sends last received message\_id, pulling unread messages.

#### **Typing Indicator Deep Dive**

> * Typing status updates generate huge QPS (e.g., 5 keypresses/sec ![][image1] 1M active users \= 5M QPS).  
> * **Optimization:**  
  * Throttle client events (e.g., send "typing\_start" at most once every 3–5 seconds).  
  * Do NOT persist typing status to disk. Use Redis in-memory key-value with TTL (e.g., SETEX typing:{chat\_id}:{user\_id} 5 true).

### **3\. Design a URL Shortener (e.g., TinyURL)**

*Converts long URLs to short aliases and redirects users efficiently.*

#### **Key Concepts & Encoding**

> * **Base62 Encoding:**  
  * Uses characters \[a-z, A-Z, 0-9\] (![][image2]).  
  * A 7-character Base62 string yields ![][image3] unique short URLs.  
> * **ID Generation Approaches:**  
  1. **Hash (MD5/SHA256) \+ Truncate:** Prone to hash collisions. Requires DB query checks and append/re-hash loop.  
  2. **Distributed Unique ID Generator (Snowflake/Counter) \+ Base62:**  
     * Generate auto-incrementing 64-bit ID ![][image4] Convert to Base62.  
     * Guaranteed no collisions.

#### **Scaling & Analytics**

> * **Read-to-Write Ratio:** Highly read-heavy (\~100:1).  
> * **Caching:** Put high-frequency short URLs in Redis. Use HTTP 302 (Found) instead of 301 (Moved Permanently) if you want to track analytics on every click.  
> * **Analytics Pipeline:** Redirect service emits click events to Kafka asynchronously to keep redirect latency sub-10ms. A analytics worker flushes metrics to ClickHouse / Cassandra.

### **4\. Design a Notification System**

*Scalable system to send multi-channel notifications (Push, SMS, Email).*

#### **Key Architecture**

> * **Push vs. Pull:**  
  * **Push:** Server pushes notification immediately to client via persistent connection or 3rd-party services (FCM, APNs, Twilio, SendGrid).  
  * **Pull:** Client periodically checks inbox for in-app updates.  
> * **Message Broker (Kafka/RabbitMQ):**  
  * Decouples request producers from worker pools handling rate-limited 3rd-party APIs.  
  * Prioritization queues: High priority (2FA OTP) vs. Low priority (Marketing emails).

#### **Reliability & Edge Cases**

> * **At-least-once Delivery:** Workers acknowledge Kafka messages only after third-party API returns success.  
> * **Deduplication / Idempotency:** Assign unique notification\_id to prevent duplicate emails/SMS if worker retries.  
> * **User Preferences:** Maintain a fast lookup cache (Redis) of user settings (e.g., "Do Not Disturb", unsubscribed channels) before queuing tasks.

### **5\. Design a Payment System**

*Handles secure financial transactions, ledger accounting, and external gateway integration.*

#### **Key Concepts & Patterns**

> * **Idempotency Keys:**  
  * Every payment request includes a unique idempotency\_key (UUID generated by client).  
  * API Gateway / Service stores key in DB with unique constraint. If a duplicate request arrives (e.g., due to network retry), return cached response without double-charging.  
> * **Saga Pattern vs. 2-Phase Commit (2PC):**  
  * **2PC:** Synchronous blocking distributed transaction across DBs; low availability.  
  * **Saga Pattern (Choreography / Orchestration):** Sequence of local transactions. If step ![][image5] fails, trigger explicit compensating transactions (![][image6]) to undo changes.  
> * **Double-Entry Ledger:**  
  * Total debits must equal total credits (![][image7]). Never overwrite records; only insert audit entries.

### **6\. Design a Distributed API Rate Limiter**

*Scales rate limiting across a cluster of API Gateway instances.*

#### **Technical Mechanisms**

> * **Redis \+ Lua Scripting:**  
  * Executing rate-limiting logic inside a Lua script on Redis guarantees **atomicity** without needing distributed locks.

> local key \= KEYS\[1\]  
> local limit \= tonumber(ARGV\[1\])  
> local current \= tonumber(redis.call('get', key) or "0")  
> if current \+ 1 \> limit then  
>     return 0  
> else  
>     redis.call("INCRBY", key, 1\)  
>     if current \== 0 then redis.call("EXPIRE", key, 60\) end  
>     return 1  
> end

> * **Synchronization Strategies:**  
  * **Centralized Store:** All gateways query shared Redis cluster. Latency overhead (\~1–2ms).  
  * **Local Memory \+ Synchronized Batching:** Local nodes count locally and sync aggregate deltas asynchronously to Redis every ![][image5] milliseconds. (Trade-off: slightly soft rate limits).

### **7\. Design a Video Streaming Platform (e.g., YouTube / Netflix)**

*Supports video uploading, transcoding, storage, and smooth streaming playback.*

#### **Key Architectural Components**

> * **Chunked Uploads:** Large video files uploaded in parallel binary chunks using HTTP Resumable / Multipart Upload protocols.  
> * **Video Transcoding Pipeline:**  
  * Original video split into short segments (.ts / .m4s, e.g., 2–6 seconds long).  
  * Worker fleet converts raw video into multiple resolutions (1080p, 720p, 480p) and formats (H.264, HEVC, AV1).  
> * **Adaptive Bitrate Streaming (ABS):**  
  * Uses protocols like **HLS** or **DASH**.  
  * Master playlist (.m3u8) links to different resolution variant streams. Client player dynamically switches quality based on real-time network bandwidth.  
> * **Content Delivery Network (CDN):**  
  * CDN nodes cache video segments close to edge users to reduce origin server load and streaming latency.

### **8\. Design a Ride-Hailing Application (e.g., Uber / Lyft)**

*Real-time driver location matching, route calculation, and dynamic surge pricing.*

#### **Core Technical Challenges**

> * **Real-time Spatial Indexing:**  
  * Standard database queries (SELECT \* WHERE lat BETWEEN ... AND lng BETWEEN ...) do not scale.  
  * Use **Geohash**, **Google S2 Geometry**, or **Uber H3** (hexagonal spatial index).  
  * Drivers report lat/lng every 4 seconds. Update ephemeral spatial index in Redis.  
> * **Matching Algorithm:**  
  * Match passenger to nearest available driver in same S2/H3 cell or adjacent cells.  
  * Uses a supply-demand matching queue to minimize ETA.  
> * **Surge Pricing Engine:**  
  * Monitor ratio of active ride requests vs. available drivers within an H3 cell.  
  * If Ratio ![][image8], apply dynamic surge multiplier to balance supply and demand.

### **9\. Design an E-Commerce Checkout System**

*Manages shopping cart, inventory reservation during flash sales, and order state transitions.*

#### **Key Challenges & Patterns**

> * **Inventory Locking Strategies:**  
  * **Pessimistic Locking:** SELECT \* FROM inventory WHERE item\_id \= 123 FOR UPDATE; (Gives strict consistency, but low throughput during high-concurrency flash sales).  
  * **Optimistic Locking:** Update using version check: UPDATE inventory SET stock \= stock \- 1, version \= version \+ 1 WHERE item\_id \= 123 AND version \= current\_version;.  
  * **Redis Pre-allocation:** Reserve inventory in Redis atomic counter (DECRBY item\_stock). If stock ![][image9], fast-reject customer immediately before touching primary DB.  
> * **Order State Machine:**  
  * Order states: Created ![][image4] Inventory\_Reserved ![][image4] Payment\_Pending ![][image4] Paid ![][image4] Fulfilled / Cancelled.  
  * Managed via explicit status enums with event listeners and saga execution timeouts.

### **10\. Design a Search Autocomplete System**

*Provides real-time search term suggestions within sub-100ms latency.*

#### **Core Concepts & Data Structures**

> * **Trie (Prefix Tree) Data Structure:**  
  * Each node stores character, and top ![][image10] most frequent completed terms.  
> * **Frequency-Based Ranking:**  
  * Offline Data Pipeline (Kafka ![][image4] MapReduce / Spark) processes search logs, counts term frequencies, and builds pre-computed Trie snapshots.  
> * **Latency Optimization (\<100ms):**  
  * **In-Memory Trie:** Serve search autocomplete directly from Trie nodes kept in RAM.  
  * **Browser & CDN Caching:** Cache response for common prefixes (e.g., Cache-Control: max-age=3600) at the client/CDN tier.  
  * **Sampling:** Do not record 100% of search queries in logs; sample 1 in 10 or 1 in 100 to reduce aggregation pipeline load.

## **Cheat Sheet: Component Quick Selection**

| Problem Type | Recommended Cache/In-Memory | Primary DB | Async / Streaming | Key Protocol / Alg |
| :---- | :---- | :---- | :---- | :---- |
| **Rate Limiter** | Redis | N/A | N/A | Token Bucket / Lua Scripts |
| **Chat App** | Redis Pub/Sub | Cassandra / DynamoDB | Kafka | WebSockets |
| **URL Shortener** | Redis | MySQL / DynamoDB | Kafka (Analytics) | Base62 / Snowflake ID |
| **Notification System** | Redis | PostgreSQL / MongoDB | Kafka / RabbitMQ | Push (APNs/FCM) / HTTP |
| **Payment System** | Redis | PostgreSQL / CockroachDB | Kafka | Idempotency Keys / Saga |
| **Video Streaming** | CDN (Edge) | MongoDB / Cassandra | S3 / Transcoder Queue | HLS / DASH / Chunked |
| **Ride Hailing** | Redis (Spatial) | PostgreSQL \+ PostGIS | Kafka | S2 / H3 / Geohash |
| **E-commerce Checkout** | Redis | PostgreSQL | Kafka | Optimistic Lock / State Machine |
| **Search Autocomplete** | Redis / In-Memory | NoSQL (Prefix Store) | Spark / Flink | Trie Data Structure |

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAZCAYAAAA4/K6pAAAAp0lEQVR4Xu3PMQtBURyG8WMQBgODUmKQ5ZrtjLIoH8BsN5sYrNzVbLBKmQ0o38YX8NQ53e55y+1adZ76Dff9364YEwr51TDSMVUBUx3TlXDFRA+uHZY6alXcMJZ9i41sX6vjiaF7XmGfXHPWwAsxDsb+/59b442BHvK0wAltPBD55+zmOKPonju4o5u8kdEMF5Rl7xn7kZbsXk1jf7miB1cfRx1Df9EHTGQSzmFSOzwAAAAASUVORK5CYII=>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAKAAAAAZCAYAAAC2CiWQAAAExElEQVR4Xu2aaahVVRiG3+bJUoMmrW6KWVQ2EJSokIVFFOGPopH+BJLSHysoowgLiwjqR1BgKdFIA0WTTRTewgZoJIfSSm5Ek83zPLzv/dbS76z2ue29zz1HN60HXrz73Wvf/XnWt6bvXCCTyWQymUwm83/mJOot6ofw7yxqs5YWxtbU5bA2r1F3Utu1tOg+TYrV05cagS2o+dQb1AvU49RE32AjsAd1K7Wcep26pPX24Octb4D6lnqOOso3qMIM2Et2o3aibqT+phb4RmQb2IfzIDWC2hH23MW+UUmUHHVoUqxie2oK9Qj1WHIvch31JixOMZv6hNplfYvesg+1lppHbU4dQH1DHenaXEndBvuc94INnD+p41yb0ryE1uzViHyf+gv2yyPzqc+pHcL1CbDOvz02qICSow5NinUOtY5aQv2B4gTck/qNOsN5ml2UgFc5r5cspZ5w19fCPrtzwvUo6jPYoI5MgCXge84rhTpQDyrjRzr/FthLzw3Xmm1+om5e38K8G6gjnFeW/tQoQZNiTfkFxQl4Hiz2SYnfT61KvF5wLCyeM513EGyliTPy0bA2Wl087wZ/v8QfEk2xX8MeVBZHtCzIOz9cnxqutTwMB8+nRgmaFGtKuwRcBIu1L/Efhs3qvd6z3gSLZ//0huMwWJsPE1/7bPm6Xwk9oMz3PA37ZdG/PlyrU++FjVBtmo8P96uyLDVK0qRYPe0SUMuzYtWm33N/8McnfrfRPlnv1ZZF8b5MPYPWAS90XzNjRPvk76mf0bo012Jv6ndqJWzWEXfBAnsbdgAQp8D2L5PDdRWGo1NFU2Jtl4BLYbHunvgaOPIPSXzPpbDDS1ndY48NyUew995HbRk8Lb8fUKNjowLOgj2nGbRj7qa+ow523gOwF1zjPHX4V6i3RA1Hp4qmxNouAftRPwG7wZew9/rV4tDg6eRbhLYJOgiqZNPx7Hc29SM1PfEXwoI4PfG18dTBQJv8IlQrerVAmq5TT7rDHitFk2JVAmq5TWm3BGsGkp8ufd1mNf49IMYGT//nIhbDPtsx6Y2qaLR9QR2T3iBXwIJQEdjzTvC1FFah01mlSbEKJaAvbUTiYBmX+DqEyO/1IUQFZb3Xz2RKRnmqPqToSwDNfiondcTOsD2Tn3qnU6eFn2fAgtAJ06O6j/ZgKrhWoZNObVKsESXgk6kJOygp1sMTX4VdDZihaDdjt5P2xv/FAlg8uzpPySVPMXlUmNbM1+e8C6h93XUpVF9TsfXkxNdMMjP8rFOOquGXbbg96OnrMFX5q1K3U5sUq0cJ+FRqwpYtFam1iY9sBZvdr3Zer1BSKdmmOW9q8JRcER3udGKe6DyhGdTXaEuhSrf2UiuCdKLUbPEr7GuYyIWwU1Jcwi6CdXSdUkHdTm1SrBGdJhWfOqcI1TFVJhoVrufBvgkZ6tTZTR6Flba0/GswPASbQTWIhTx9JvqWJ/aDiuYDsG9IKqGXKLuLpELothuaDjKXWgPr3GepA1tvl6ZOpzYpVnEibH8Ui+fSp7AB45NLs7pOmDpFvgI7Lad7wl4yAlZOGaA+hv1RQhwcQluf9POPetG126Sp26kbgybFminJ5NTYhGlSrJlMJpPJZDKZTCaTacc/ECqP7oPCPUgAAAAASUVORK5CYII=>

[image3]: <data:image/png;base64,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>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABUAAAAYCAYAAAAVibZIAAAAY0lEQVR4XmNgGAWjYPiCJHQBaoDtQCyGLkgpCATiDnRBaoCVQOyELogMlgHxETLwTSD+B8TNDFQCqgwQg43RJcgF7EB8FIgV0MQpArlAnIEuSCk4AMSc6IKUAhN0gVEwCiAAACBLE8KU5AMmAAAAAElFTkSuQmCC>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABMAAAAaCAYAAABVX2cEAAABDElEQVR4XmNgGAXDFzgD8S0gfg/E/4H4IKo0GJwF4n8MEPlvQDwbVRoTbAHiewwQDZZociCQDcTLgJgJXQIdsALxGSCOYIAYthZVGgymMEB8QRDYAPFkIGYG4vtA/BeIVVBUQCxjRxPDChqB2A/KzmWAuG4aQppBCoi3I/HxggNAzAtlcwHxGwZIQItAxeKBuAjKxgv4GCCGIYMmBojr6qD85UCsi5DGDfyBuB5NTBSIvwPxKyDmBuLLqNK4ASiWrNEFgWA6A8R1c4B4EZocTnAOiFnQBRkgsQmKVZCBMWhyWIEdEJ9GF0QCoPQGMkwCXQIZuAHxAwZEFnkCxPbICqDAnAGSlUbBKBhQAADIFjDhxd8YOAAAAABJRU5ErkJggg==>

[image6]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAG4AAAAaCAYAAABW6GksAAACSklEQVR4Xu2YP0hXURTHD5UIpU5aEg4OKQ4JTUYoCSWiQzWWIEZTiLS0uRgFrS6JDQVBQ9GQgwq6BAVBQ+UiLSIWESJi6KD9Icq+x3PF+w79/sDv6r3X7gc+8H7nPOF83+XJfZcokUgkEolEaNTrQuTU68J+ogw2wWG4pnox4izPeTgHV+EmfJVtb/Ee/iHpf4MPsu1doxl+hW/gZ7iebUfHruSZhAski3NG9ZgB+AQe0I09YpocBQ0EJ3n49X0Hr5As3PNse4sRkrfTF06CBoSTPG3wHjwIP8Lf8ETmDlnYclXbS5wEDQgneW7Di+b6BslbN7rTpuNwyvrtAydBA8JJnpew0lwfhiskm5BqU7sKb5prXzgJGhAl56kiWTibOyRv3ZD5/ZRkR+QTDrqhixFTcp5L8Jaq1cDvcBkegbPZdl4ewddFet38TTFwUJ5pv1ByHt4ttuoiuE/y1j2Ej1XPBxz0hy5GTMl5ZuAhXSTZVfLukhevV/V8wEF/6qKhDvaRfNbkogOe0kWLY7CHZGediwuwURctipljm3x5CnIWvtVFC/6e44Wr1Q0PvIC/6N8PZYJkzkHdMJwk6fOpRS74QfI913TDwAvP/Q+6YVFoDpt8eXLSCT/RzjHWF9hu32A4TXLc5Qve1c7DRZI5WT7f41qXdR8/KK6PWTWboyTfp+O6YXGXZGFbdMPQAJco/3FfoTmKzfNfUQGf6aIHQpkjGrphvy56IJQ5ooA3FPxvcPvAwBehzBEN5+BlXfRAKHMkEolEIhEVfwHRtY28+bfHMwAAAABJRU5ErkJggg==>

[image7]: <data:image/png;base64,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>

[image8]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACgAAAAaCAYAAADFTB7LAAABbUlEQVR4Xu2VvStHURjHH/JaQlJGg+SlRLF4i9nAZqaEsohFkvwD8g8YRDYZJMrrZpC3QVJGBoNBKTLxOT336p7zM/zu716DOp/6DPf5PnWfzj3nHhGPx/PvyHMLf80yPuJX4DuuBFkzvkWyF5wOMot+3MFep54mW6JDzDj1OTzAJqeeQS2uijb3OVkadIsO+ID5QW0It7EobMqGOlzDQ0l/0EvRIQcCzVcrtjpiUI/reCTpDToqOuAt7mOpHedGA26KDpp0j5aIHgQzZJuTJcacuD3RPWpelAud+Cw6YHiSU6ESl/AKR6wke9rxGBvxE1+xzOrIgQpcxGscwwI7zppWPMGq4HlDdBWnfjpiUo4LeIMTWGjHsWjBU6yO1DpEB7yXmDeHWfJ50RWblJj/Jwfz4mF8whonM5yLDjnoBr9hNv0sXoiuWJLBDGeiV1p4he1GMvNrMSsXZh94h12Rngx6cFySfUqPx+P5j3wD091D7u193oMAAAAASUVORK5CYII=>

[image9]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAZCAYAAABQDyyRAAABXUlEQVR4Xu2VzSpFURiGX8m/AQOFlEhmMjByKXIDIv8/GUoxcwHKDWCkMHVSRvJTSq6AiSuQ8H7nW3tbPu191t46maynnsF+9zr7+9baa68DRCL1o5Fu0Tt6Rc/pqD+g3uzRe9rprmfoC+1JR5SgmU7RFnvDMEDfoGMTGqAN7HhZMG10nl7TRejD8pijn3TM5BX6aLJc2ukK9D0uQxsJ4QDawKDJT+gHAp4jhdeghZcQ8APDGbSBPpMfu3zY5ClJ4Vvokrf+vB3MBbRQr8kPXT5u8uoMkxlL4VqbrBYVFGxgkj7TDZSftU/WKzhy+YjJq8jyr0O/3QX8rZF9aKEhk8smlDx3T3XguxH55HIHZyCHjhSaMLmciE8my0RWZBXlvoR++k6nvayJvtJdLwtCCksDNyh2FshRLM13uetN6EnYnY4oiOyJWXqJsCbkz2ibPkBP0FP83hORSOT/+QKK7UA+hY6trwAAAABJRU5ErkJggg==>

[image10]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABMAAAAaCAYAAABVX2cEAAABDUlEQVR4XmNgGAXDFzgA8XUg/gLE/4H4AxDfBGIfJDWtUDkQ/grEs5HksIIdDBDFRugSQGALxMeB2AWIGdHkMAArEH8G4lcMqIqZgLgaiJuAmAVJHC+wYYC4aimSmAwQLwdiZyQxokAjA8SwOCg/EIiPArEoXAUJ4BgDxDAlIJ4MxD8ZIN7mR1ZEDABp+APE74B4IxCbAfEMBojhpUjqiAIgL4E0gmKTFyqmBsT/gPgRAwkBDwLTGSCGuaGJg1wJEo9CE8cL7gLxDyDmRBO3Y4AYdh5NHCfQZIBo2IcuAQW3GCDy3ugSyMCBAZKFPjFAFINi7ioQu0Pl2aDyoHADyYNiF+RCZqj8KBgFdAUA1cE4UD3uB1gAAAAASUVORK5CYII=>
# **System Design: E-Commerce Checkout System**

## **1\. Requirements & Scope**

### **Functional Requirements**

> 1. **Cart & Order Creation:** Transition user cart items into a pending order.  
> 2. **Inventory Reservation (Locking):** Reserve stock temporarily (e.g., 10–15 minutes) during checkout to avoid overselling without permanently reducing stock before payment succeeds.  
> 3. **Flash Sale Handling:** Support sudden traffic spikes (100k+ TPS) for high-demand items without overwhelming backend databases.  
> 4. **Payment Processing & Retries:** Process payments via third-party gateways (Stripe, PayPal, Adyen) with strict idempotency and resilient retry mechanisms.  
> 5. **Order State Management:** Robust state machine tracking the order lifecycle from CREATED to COMPLETED or CANCELLED.

### **Non-Functional Requirements**

> 1. **Strict Consistency (Inventory):** Zero overselling. Under no circumstances should more units be sold than available.  
> 2. **High Availability & Fault Tolerance:** Core services must remain resilient during external payment gateway outages or flash sale spikes.  
> 3. **Low Latency:** Checkout initiation and response within ![][image1].  
> 4. **Idempotency:** Preventing duplicate charges or duplicate inventory drops under network retries or double-clicks.

## **2\. High-Level Architecture**

                                    \+-----------------------+  
                                    |     Client App /      |  
                                    |     Web Frontend      |  
                                    \+-----------+-----------+  
                                                |  
                                                v  
                                    \+-----------------------+  
                                    | API Gateway / WAF /   |  
                                    | Rate Limiter (Kong)   |  
                                    \+-----------+-----------+  
                                                |  
                                                v  
                                    \+-----------------------+  
                                    |   Checkout Service    |  
                                    \+-----+-----------+-----+  
                                          |           |  
               \+--------------------------+           \+--------------------------+  
               |                                                                 |  
               v                                                                 v  
\+-----------------------------+                                   \+-----------------------------+  
|      Inventory Service      |                                   |        Order Service        |  
|  \+-----------------------+  |                                   |  (State Machine Engine)     |  
|  | Redis (Distributed    |  |                                   |  \+-----------------------+  |  
|  | Locks / Token Bucket) |  |                                   |  | PostgreSQL DB (Orders)|  |  
|  \+-----------------------+  |                                   |  \+-----------------------+  |  
|  \+-----------------------+  |                                   \+--------------+--------------+  
|  | MySQL/PG (Inventory)  |  |                                                  |  
|  \+-----------------------+  |                                                  v  
\+-----------------------------+                                   \+-----------------------------+  
                                                                  |       Payment Service       |  
                                                                  |  \+-----------------------+  |  
                                                                  |  | Idempotency Key Store |  |  
                                                                  |  \+-----------------------+  |  
                                                                  \+--------------+--------------+  
                                                                                 |  
                                                                                 v  
                                                                  \+-----------------------------+  
                                                                  | Third-Party Payment Gateway |  
                                                                  |    (Stripe / PayPal)        |  
                                                                  \+-----------------------------+

## **3\. Deep Dive: Key Technical Components**

### **A. Inventory Locking & Oversell Prevention**

To prevent overselling while maintaining high throughput, inventory reservation uses a **Two-Tiered Locking Strategy**:

#### **1\. In-Memory Atomic Reservation (Redis \+ Lua Script)**

During high concurrency (like flash sales), database updates cause row-level lock contention. We maintain inventory counts in Redis and decrement them atomically using Lua scripts.  
\-- Redis Lua Script for Atomic Inventory Check & Reserve  
local key \= KEYS\[1\] \-- e.g., "inventory:item\_123"  
local quantity \= tonumber(ARGV\[1\])

local current\_stock \= tonumber(redis.call('get', key) or "0")

if current\_stock \>= quantity then  
    redis.call('decrby', key, quantity)  
    return 1 \-- Success  
else  
    return 0 \-- Insufficient stock  
end

#### **2\. Database Inventory Reservation Strategies**

> * **Optimistic Locking (Standard Load):** Uses a version column in PostgreSQL/MySQL.  
>   ![][image2]  
>   If no rows are updated, another request changed the state, and the request is safely rejected or retried.  
> * **Pessimistic Locking (SELECT ... FOR UPDATE):** Guarantees strict ordering but reduces concurrency. Used primarily for low-volume, high-value items.

#### **3\. Reservation Timeout & TTL Handling**

When inventory is reserved:

> 1. A temporary hold key hold:{order\_id}:{item\_id} is created in Redis with a TTL (e.g., 15 minutes).  
> 2. If payment completes before TTL expires, the hold is finalized (converted to permanent deduction in RDBMS via an asynchronous worker).  
> 3. If the TTL expires without payment completion, a Redis Keyspace Event triggers an asynchronous release of the stock back into the main pool:  
>    ![][image3]

### **B. Flash Sale Management Strategies**

During flash sales (e.g., Black Friday or limited drops), traffic surges by orders of magnitude. The system relies on three protective layers:  
\[Incoming Requests\]   
        │  
        ▼  
\[Virtual Queue / Rate Limiter\]  \--\> Drops or queues traffic beyond threshold  
        │  
        ▼  
\[Pre-Warmed Redis Cache\]        \--\> Handles atomic stock check/decrement  
        │  
        ▼  
\[Kafka Message Queue\]           \--\> Decouples order creation from instant DB writes  
        │  
        ▼  
\[Order Processors\]             \--\> Batch updates RDBMS state asynchronously

> 1. **Virtual Waiting Room & Rate Limiting:**  
   * Token bucket or sliding window algorithm applied at the API Gateway level per user ID or IP address.  
   * Users exceeding capacity are directed to a queue page with periodic polling or WebSockets.  
> 2. **Pre-warming Inventory:**  
   * Stock counts are pre-loaded into Redis cluster shards prior to sale launch.  
   * Read traffic for product descriptions, images, and stock status is completely served from CDN and Redis cache, shielding the primary database.  
> 3. **Asynchronous Order Ingestion via Message Queue (Kafka):**  
   * Upon successful Redis inventory reservation, an OrderPlaced event is published to a Kafka topic.  
   * Workers consume events at a controlled rate to write orders to the relational DB, preventing database pool exhaustion.

### **C. Payment Retry Strategies & Idempotency**

Payments are non-deterministic over networks (e.g., timeouts, dropped packets, gateway downtime).

#### **1\. Idempotency Key Design**

To prevent duplicate charges on network retries:

> * The client or API gateway generates a unique **Idempotency Key** (e.g., idempotency\_key \= Hash(user\_id, cart\_id, total\_amount)).  
> * The Payment Service records this key in a central store (Redis/DB) with status PENDING, SUCCESS, or FAILED.

Client                    Payment Service                  Payment Gateway  
  │                              │                                │  
  ├──── Charge (Key: ID\_123) ───►│ Check Key ID\_123               │  
  │                              ├─ New Key? Save (PENDING) ─────►│  
  │                              │                                ├─ Process Charge  
  │                              │◄── Network Timeout Exception ──X  
  │                              │                                  
  ├──── Retry  (Key: ID\_123) ───►│ Check Key ID\_123               │  
  │                              ├─ Found PENDING: Query Gateway─►│  
  │                              │◄── Gateway Status: PAID ───────┤  
  │◄── Order Success ────────────┼─ Update Key (SUCCESS)          │

#### **2\. Retry Patterns & Circuit Breakers**

> * **Exponential Backoff with Jitter:** Retries intermittent network failures with randomized delays to avoid "thundering herd" problems on payment gateways:  
>   ![][image4]  
> * **Circuit Breaker Pattern (Resilience4j / Hystrix):**  
>   If error rate from a specific gateway exceeds a threshold (e.g., 50% failures over 1 minute), open the circuit and instantly fallback to a secondary gateway (e.g., Stripe ![][image5] Adyen) without waiting for timeouts.

#### **3\. Payment Reconciliation Engine**

To handle asynchronous notifications and dropped responses:

> * **Webhooks:** Payment gateways push events (payment\_intent.succeeded) to webhook endpoints. Webhooks are processed idempotently.  
> * **Cron/Reconciliation Jobs:** A background reconciliation worker scans orders stuck in PAYMENT\_PENDING for ![][image6] and queries the payment provider API directly to resolve missing states.

### **D. Order State Machine Architecture**

An order must transition through explicit, well-defined states. Transitions are strictly validated, immutable, and event-driven.  
                  \+-------------------+  
                  |      CREATED      |  
                  \+---------+---------+  
                            |  
                   (Reserve Inventory)  
                            |  
                            v  
                  \+-------------------+  
                  | INVENTORY\_RESERVED|  
                  \+----+---------+----+  
                       |         |  
      (Payment Succeeded)       (Payment Failed / Timeout)  
                       |         |  
                       v         v  
\+------------------------+     \+------------------------+  
|        PAID            |     |       CANCELLED        |  
\+-----------+------------+     \+-----------+------------+  
            |                              |  
    (Fulfillment Started)             (Release Stock)  
            v                              v  
\+------------------------+     \+------------------------+  
|      FULFILLED         |     |    STOCK\_RELEASED      |  
\+------------------------+     \+------------------------+

#### **State Machine Implementation Matrix**

| Current State | Event | Target State | Action Required |
| :---- | :---- | :---- | :---- |
| CREATED | RESERVE\_STOCK | INVENTORY\_RESERVED | Lock item in Redis/DB with TTL. |
| INVENTORY\_RESERVED | PAYMENT\_SUCCESS | PAID | Confirm payment, convert stock lock to permanent, notify fulfillment. |
| INVENTORY\_RESERVED | PAYMENT\_FAILED | CANCELLED | Trigger RELEASE\_STOCK saga. |
| INVENTORY\_RESERVED | TTL\_EXPIRED | CANCELLED | Release stock, inform client timeout. |
| PAID | INITIATE\_REFUND | REFUNDED | Call gateway refund API, restock inventory. |

#### **Distributed Transactions: Saga Pattern (Orchestration-Based)**

Since Checkout spans multiple services (Order, Inventory, Payment, Notification), consistency is maintained using an **Orchestrator Saga**:  
Checkout Orchestrator  
 ├── 1\. Reserve Stock (Inventory Service) ──\> \[Success\]  
 ├── 2\. Process Charge (Payment Service) ────\> \[Failure\]  
 └── 3\. Execute Compensation:  
        └── Release Stock (Inventory Service)

## **4\. Key Bottlenecks & Mitigations Summary**

| Challenge | Bottleneck | Mitigation Strategy |
| :---- | :---- | :---- |
| **Hotspot DB Locks** | Millions clicking buy on 1 item. | Pre-allocated Redis inventory \+ Kafka queue ingestion. |
| **Double Charges** | Network latency leading to user retries. | Strict server-side Idempotency Keys across gateway calls. |
| **Stale Reservations** | Users abandoning checkout after reserving stock. | Automatic TTL expiration via Redis key events or scheduled janitor service. |
| **Inconsistent State** | Payment succeeds, but DB crashes before updating order. | Event-driven architecture with **Transactional Outbox Pattern**. |

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFMAAAAZCAYAAABNcRIKAAAD70lEQVR4Xu2XWahVZRTHl7MVDtiElWIPQjaACoL6oPfB4UEKRBx6EPEhCqVZpVAfnCpERVBEMRCHRBSJUBwi9BpK4ZCCIkYOWOKQM5IvTq2fa33nrLPvPZxz9YJe3T/4w1nr+84+Z6+91vrWFsnJycnJeRxor1qhuqw6p1qver1kh9FTtVO1W/WH6ktVs5IdIi+o1qj2qfarlqnalex4giEYtaoPVc1V/VXnVRdUrxS3SVfVFdVYtzupjqqmFXaItFDtVX0vdl3sH1S/hD1Nktaq91VtsgsZhoplW2S86p5YUBJLVMeCDR+p/lN1cHuU2PfiQ3jDfYODr8nwjOpjsTL7VOqWYZYZqtuqz4PvVbEAUPLANcjUjYUdRo3YPoIIG8RaRYTsvCP2MJoMz6q+UB0UCwxBrQb2EpDVwUePw3fd7dfcpq9Gern/W7ePq04Vlwtwnd+yznqgzTxSCOIksSB+JtUHMZHawYvBR98kSHvc7uM2h0nkLfevcpuS/7O4XOCi6u+s02kl1j4uiWU/bYED7GfVWdVEsQNyoepH1QnVnPvfLPK2r/0k1v+poHlxQyVSEDlVKeu2pcsPxXIpLd+Bbi8t7DB6uJ8bgbtSt68CQbqadTq0EAK4Q3VTLCAED75T3VJtU3V33zCp24NPqgYEm0AuDnZZyLyUiQSx0gHTUMg2bmBl8NVI5WASFD43NJiJRWLfrwm+0e6bHnyd3TfV7ZfdHlnYIfKOamawy9JPLP2nSONmI5Dth8Wyg/JLlCvzN91PWUK5Mv9XdSbrzEAZc604k45wH9mYeMl9KVgccKfdR4KRkX19rSq46cmqQ6pPpPGCyky4SayPRlI2xGyFdABRjkAgubEsHEC/Z50Z5otdK97LcPcNCj5eCvDNCj6q6VexNsMa08m4sF4Vz0kxqIxBDT18IhxeNP3YNmJZM8gT6Ah9iz8/xu11qhvF5fuQ4ezJtogs9LlqgslBGYNJYjErQ0fVe2IPlf9baSysFy7Iq92Dnug1ql1i10lwU3GcYU78K9jAKMahwU1AGtqZUxO93Tck+OojlXm1wZztdjfVP1IaOA4j/tcDBTNBEAnmAal+1uQ1kdHllOqIi0OEJ8s7eoJZ85oUy4eb4ia+LuywOTG9TvK5pWqzanvYUw4ylyCltyngUMH3bvClF4q5bndz+4O0wT9vCfZDwdOdINZHKgWUfsefqU/fhH1AltWKBSxNE1meV60Vaz2IAyFmfBb6Mw+StyR+kzcoEoEJgQMNH1lGP/9KbCrAR1+kUrqIjVULVFvFgsibWKyOpwoefipJTmcCHH1kOb0cP+vAWmMdvDk5OTk5OTlNjv8B6L3sOITBFYAAAAAASUVORK5CYII=>

[image2]: <data:image/png;base64,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>

[image3]: <data:image/png;base64,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>

[image4]: <data:image/png;base64,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>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABUAAAAYCAYAAAAVibZIAAAAY0lEQVR4XmNgGAWjYPiCJHQBaoDtQCyGLkgpCATiDnRBaoCVQOyELogMlgHxETLwTSD+B8TNDFQCqgwQg43RJcgF7EB8FIgV0MQpArlAnIEuSCk4AMSc6IKUAhN0gVEwCiAAACBLE8KU5AMmAAAAAElFTkSuQmCC>

[image6]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGwAAAAZCAYAAADUicu/AAAEZUlEQVR4Xu2YachVRRjHn8wsbF80DCotWrCQKIIW2wgiqFArqg8VfSh9iSiqL2ERL5a02Ep9CFppIYpUjPYFzIz2DFpNaSOtMAojKkSr/69n5r1z5t73eLdXKeYHf+49/zN37jnzzDzznGNWKBQKhUIhZ0A6RdpN2lY6SlooHZk26jPbS8ul1/MThY3DoP2d6VlpTNqoz0yUNki/SVtWT40ITMjxuflfZbH0ufSdtFSaJY1KG4wQx0qH5OYI8bx0cG5uCo6XnpaOyfxeeNV8xv9f2Vn62TZTwGBv6T7pJem47Fw3vGK9BWyL3GiDsdJe0mH5iUA3fUboO7KrNN88zW+2gEX2lR6SXrbeAsfvLzNPG+9Kz0kHVlo085j0vbROOlq6U1okrZLulbaSrpCekD6VFkg7/PtL5xtr7JeR4fr8VrrbGkE8yRq/fSt42yUeGh38T8z3SbxfpJ/MrynlfPP7Xiy9I52ZnNtFut/8Ol4Mn0zwnthPeti8o24Cx4XcZo1963pptbTHUItm9pTmmQ/EB9IBwT85eG9IZwSPWf6HNDccRx63asA21uep4ZgiZR9pjTUCBqS+Z6waMLgkeK1W2OXm9zoxHE+V/pJODMcPSNeG73Ca9HFy3BPcILOUwHWyx022apExyfwG70i8VhAQ2g0m3u7BY19MoYRnJafcYtWAQV2f6cDBR1YNGHDN7QaMqvFP6cbMZ7U9Fb5/Zr66U8gWfYUAkNbY47bJzrUDM5gb/CI/kTHdvB2zLsJqwmOlpJAWl2TezdYcsLo+5yQeLLPeAnZu8L807ydqhflKhUdDG1I4Wezs4PeNncxnJynlgsqZ1vB88qt0VuaTFsj9dTCo3AwpK0JawiOtppBG8odkZnYesLo+r0s8YCX0EjDSIf5FmZ+yo3nQSOm0RRR8PUPHpAxm3YVWveA6Bs0v4urEo8rCY6bVwZ4y3ODmAWPzzwN2kzUHrK7PPGBvmxcJKXdZc8AuDt6UcPyI+T3OCH567zmnh8+tzd8Akbn4zUFDLTqEyusa6UPzB16qs04gBVH5pG8bjjC/qBsSrxUxfbUa3FYBW5p5rQLWSZ9vSu9nHs+otE3f0rCC8OJDOkUW48TYrbXmVE3F+WT4/pV5URehX1YbY9QRdDrbfEUNWPevkSg2GMi4Z5BSXzPfc3jfV8c55gMxLfHGBe/WxANWa74abrfm1VDXJ0VKyoPm+0+EWU8AYnBiv4cGj3FiT0+Ln/PM0/+l5o8NjMc95lsFfG2+d8WibH/pR/Pxbwv+8ErpPfMV1W2gUqiWKLFXmr+eIkfzIrgOqqjfzQeCT55trjJ/zsFbbz47TzB/tsJD9H94OEcbPMpqVlS7fUYmSC+YZwiCR0aIhQwaHGrp28UP5pOR1JbCfzNpKSxYtQQxQnuugcqb96sEO/99LTwnzLTOU1+/YeLEWccnx0yemFqZrXjM8niteHynDefigzBtULt91sHetCleJhcKhUKhUCgUCl3wD7N/IUCZULgcAAAAAElFTkSuQmCC>
# **Question 5 Deep Dive: Design a Payment System**

A Payment System processes financial transactions between buyers and sellers, interfacing with third-party Payment Service Providers (PSPs) like Stripe, PayPal, or Adyen. Financial systems require absolute precision: **zero data loss, zero duplicate charges, and complete auditability.**

## **1\. Requirements & System Constraints**

### **Functional Requirements**

> * **Payment Execution:** Allow users to initiate payments using credit/debit cards, bank transfers, or digital wallets.  
> * **Payment Status Tracking:** Provide real-time and historical status of transactions (Pending, Succeeded, Failed, Refunded).  
> * **Integrations:** Interface with external Payment Service Providers (PSPs) and acquiring banks.  
> * **Double-Entry Ledger:** Record all money movements in an immutable, append-only financial ledger.  
> * **Reconciliation:** Automatically verify internal financial records against external bank/PSP settlement reports daily.

### **Non-Functional Requirements**

> * **Strict Idempotency:** Guaranteed "exactly-once" payment processing. Network retries must never result in duplicate charges.  
> * **Data Consistency:** Zero tolerance for financial discrepancies. Strong consistency for ledger entries; eventual consistency for multi-service orchestrations.  
> * **High Availability & Fault Tolerance:** Gracefully handle PSP downtime, network timeouts, and webhook delays without losing state.  
> * **Security & Compliance:** Compliance with PCI-DSS (Payment Card Industry Data Security Standard) and tokenization of sensitive payment details.

### **Back-of-the-Envelope Estimation**

> * **Daily Transactions:** ![][image1].  
> * **Average QPS:** ![][image2].  
> * **Peak QPS (Flash Sales / Cyber Monday):** ![][image3].  
> * **Ledger Entries:** Each transaction generates at least ![][image4] ledger entries (1 debit, 1 credit).  
> * **Storage Footprint:** ![][image5].

## **2\. ACID vs. Eventual Consistency in Payment Systems**

Financial systems must balance ACID properties for local data integrity with Eventual Consistency for distributed service workflows.

| Dimension | ACID Consistency (Local Database) | Eventual Consistency (Distributed Systems) |
| :---- | :---- | :---- |
| **Scope** | Single database instance or shard (e.g., Ledger database). | Microservices spanning Payment Service, Order Service, and PSPs. |
| **Guarantees** | Atomicity, Consistency, Isolation, Durability for account updates. | System reaches a consistent state over time via event streams and retry workers. |
| **Mechanism** | Database transactions, row-level locks, WAL (Write-Ahead Logs). | Saga Pattern, Idempotent APIs, Event Sourcing, Asynchronous Webhooks. |
| **Usage** | Creating ledger entries and updating internal user balances. | Coordinating order fulfillment after payment processing. |

## **3\. High-Level System Architecture**

                                    \+-----------------------+  
                                    |     Client App        |  
                                    \+-----------+-----------+  
                                                |  
                                    POST /v1/payments (With Idempotency Key)  
                                                v  
                                    \+-----------------------+  
                                    |     API Gateway       |  
                                    \+-----------+-----------+  
                                                |  
                                                v  
                                    \+-----------------------+  
                                    |    Payment Service    |  
                                    \+-----------+-----------+  
                                                |  
            \+-----------------------------------+-----------------------------------+  
            |                                   |                                   |  
            v                                   v                                   v  
\+-----------------------+           \+-----------------------+           \+-----------------------+  
| Idempotency Engine    |           | Payment Orchestrator  |           | Double-Entry Ledger   |  
| (Redis / DB Unique Key|           | (Saga Engine)         |           | (PostgreSQL / DB)     |  
\+-----------------------+           \+-----------+-----------+           \+-----------------------+  
                                                |  
                                                v  
                                    \+-----------------------+  
                                    |     PSP Service       |  
                                    \+-----------+-----------+  
                                                |  
                             \+------------------+------------------+  
                             | (Primary)                           | (Fallback)  
                             v                                     v  
                  \+--------------------+                \+--------------------+  
                  |    Stripe API      |                |    Adyen / PayPal  |  
                  \+--------------------+                \+--------------------+

## **4\. Deep Dive: Idempotency & Deduplication Engine**

Network failures, timeout errors, and client-side double clicks often trigger request retries. To avoid double-charging a customer, every payment endpoint **must be strictly idempotent**.

### **Mechanics of an Idempotent API**

> 1. **Client Generation:** The client generates a universally unique idempotency\_key (e.g., UUID c8a21f8a-5431-4a11-b1e0-32110a30018a) before sending the request.

POST /v1/payments  
Content-Type: application/json  
X-Idempotency-Key: c8a21f8a-5431-4a11-b1e0-32110a30018a

{  
  "user\_id": "usr\_7721",  
  "amount": 4999,  
  "currency": "USD",  
  "payment\_method\_id": "pm\_card\_visa\_123"  
}

> 2. **Idempotency Lock & State Check (Database/Redis):**  
   * The server executes an atomic insertion into the idempotency\_keys table or Redis using a UNIQUE constraint:

INSERT INTO idempotency\_keys (key, user\_id, status, response\_body, created\_at)  
VALUES ('c8a21f8a-5431-4a11-b1e0-32110a30018a', 'usr\_7721', 'IN\_PROGRESS', NULL, NOW())  
ON CONFLICT (key) DO NOTHING;

> 3. **Handling Scenarios:**  
   * **First Time Request:** Insert succeeds. The server processes the payment.  
   * **Concurrent Request (Race Condition):** Insert fails due to key conflict. The server returns HTTP 409 Conflict or waits for the first request to complete.  
   * **Retry After Completion:** The server fetches the cached response\_body associated with the key and returns it immediately **without re-calling the PSP**.

## **5\. Distributed Transactions: Saga Pattern**

Traditional 2-Phase Commit (2PC) protocols perform poorly across microservices and external third-party APIs because they hold blocking database locks, creating single points of failure. Instead, payment systems use the **Saga Pattern (Orchestration-based)**.  
\+---------------------+      1\. Execute Payment      \+---------------------+  
| Payment Orchestrator| \---------------------------\> |     PSP Gateway     |  
| (State Machine)     | \<--------------------------- | (Stripe / Adyen)    |  
\+----------+----------+      2\. PSP Success          \+---------------------+  
           |  
           | 3\. Record Entries  
           v  
\+---------------------+      4\. Reserve Stock        \+---------------------+  
|   Ledger Service    | \---------------------------\> |  Inventory Service  |  
\+---------------------+                              \+---------------------+  
                                                                |  
                                                     5\. Stock Out of Limit\!  
                                                        (Trigger Compensation)  
                                                                |  
                                                                v  
                                                     \+---------------------+  
                                                     | Payment Orchestrator|  
                                                     \+----------+----------+  
                                                                |  
                                                     6\. Execute Refund  
                                                                v  
                                                     \+---------------------+  
                                                     |     PSP Gateway     |  
                                                     | (Compensating Step) |  
                                                     \+---------------------+

### **Steps in Saga Orchestration:**

> 1. **Execute Payment:** Orchestrator calls PSP Service to process card charge.  
> 2. **Record Ledger:** Orchestrator commands Ledger Service to create debit/credit entries.  
> 3. **Reserve Inventory:** Orchestrator contacts Inventory Service to fulfill item.  
> 4. **Compensating Action (Failure Case):** If the Inventory Service fails (e.g., out of stock), the Orchestrator initiates a **compensating transaction** to refund the payment via the PSP Service and reverse ledger entries.

## **6\. Double-Entry Ledger Accounting**

A cornerstone of financial software is the **Double-Entry Ledger system**.

### **Core Rules**

> 1. **Immutable Log:** Records are strictly append-only (INSERT allowed; UPDATE and DELETE forbidden).  
> 2. **Balanced Equation:** Every transaction consists of at least two entries: a **Debit** and a **Credit**.  
>    ![][image6]

### **Accounting Entries for a $50 Purchase**

> * **Buyer's Account:** Debited $50 (Asset decreases / Cash outflow).  
> * **Merchant's Account:** Credited $50 (Revenue increases / Payable inflow).

### **SQL Schema (ledger\_entries)**

CREATE TABLE ledger\_accounts (  
    account\_id UUID PRIMARY KEY,  
    owner\_id UUID NOT NULL,  
    type VARCHAR(20) NOT NULL, \-- ASSET, LIABILITY, REVENUE, EXPENSE  
    currency VARCHAR(3) NOT NULL  
);

CREATE TABLE ledger\_transactions (  
    transaction\_id UUID PRIMARY KEY,  
    idempotency\_key VARCHAR(255) UNIQUE NOT NULL,  
    description TEXT,  
    created\_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT\_TIMESTAMP  
);

CREATE TABLE ledger\_entries (  
    entry\_id UUID PRIMARY KEY,  
    transaction\_id UUID REFERENCES ledger\_transactions(transaction\_id),  
    account\_id UUID REFERENCES ledger\_accounts(account\_id),  
    amount DECIMAL(18, 4\) NOT NULL, \-- Positive for Credit, Negative for Debit  
    created\_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT\_TIMESTAMP  
);

## **7\. Handling PSP Timeouts & Edge Cases**

When a request to Stripe/PayPal times out due to network drop, the state of the charge is unknown (**Did the PSP process the payment or fail?**).  
   Payment Service                  PSP (Stripe)  
          |                              |  
          |-------- Charge Card \--------\>|  
          |        (Timeout Exception\!)  |  
          | X \< \- \- \- \- \- \- \- \- \- \- \- \- \-|  (Payment actually succeeded on PSP side)  
          |                              |

### **Mitigation Strategies**

> 1. **Idempotent Retries:** Retry the same request to the PSP using the exact same psp\_idempotency\_key. The PSP returns the original transaction status without charging twice.  
> 2. **Status Polling:** Query the PSP’s GET API (GET /v1/charges?client\_reference\_id=...) to verify if the payment was recorded before attempting any retry or cancellation.  
> 3. **Webhook Reconciliation:**  
   * PSPs emit asynchronous webhooks (charge.succeeded, charge.failed).  
   * Webhook handlers update local status asynchronously.  
   * Webhook processing must be **idempotent** because PSPs send webhooks at-least-once.  
> 4. **Nightly Reconciliation Engine:**  
   * Download settlement files (CSV/FINMT940) directly from PSPs and banks at the end of the day.  
   * Compare internal ledger transaction records against bank settlement files using batch engines (Apache Spark / Flink) to flag missing or mismatched amounts.

## **8\. Summary Checklist for Interviews**

> 1. **State Consistency Model:** Clearly separate local ACID database transactions from multi-service eventual consistency via the **Saga Pattern**.  
> 2. **Explain Idempotency End-to-End:** Detail the role of client-supplied X-Idempotency-Key and database UNIQUE constraints to enforce exactly-once execution.  
> 3. **Discuss Double-Entry Accounting:** Highlight why financial ledgers are append-only and explain how ![][image7].  
> 4. **Address PSP Network Timeouts:** Detail status polling, idempotent PSP retries, and asynchronous webhook handling.  
> 5. **Detail Reconciliation:** Explain daily batch processing against bank settlement files to ensure zero financial drift.

[image1]: <data:image/png;base64,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>

[image2]: <data:image/png;base64,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>

[image3]: <data:image/png;base64,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>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAoAAAAaCAYAAACO5M0mAAAA1ElEQVR4Xu3RPwtBURzG8YOFhbKYmEwG8grcRFlkMJiMMnsJyqSMJruXYPAGbAaRBa9AKTFI/nyvc0/97uWWVXnq0+0859e5t3OV+q1UscDJebYQcE2QEuZIIIohHujJITszFMQ6hC3uSMryhh1ipiQjpU9tmyKIg1OmTUkGTtcRncqjLAsyVXrQ27uSwhUrpd/omzGOyHo3ZJo4w/L0b/lqMIc9it4NmTjWqIjOQkOsX5c+QV2WpIuaLPpKf9fSYV/LBhdkzFBE6Yv9xP7XYTP4j2+ePKUs7suvVZQAAAAASUVORK5CYII=>

[image5]: <data:image/png;base64,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>

[image6]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAmwAAAAvCAYAAABexpbOAAAFhUlEQVR4Xu3dachtUxzH8b95dpGMeUVkiEJE3qHMU4Y3uHXxQpIhEuK5SmZekELihVBCGZKx5xEyZiglEZfM83DN4//XWqu9zv85077Pc657ju+n/j17r3322efsN8+vtddaxwwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsIJ71+uHXJ97feH1Za5vvL7zWur1a6hfdPIEO8nrR6+vrPO+aP9br++9frbZ9+UOnQwAADCfzvL6x1IA2ykcq23stYvXjV4fWTpnkm1g6TsOCmBreu3r9ZTXn16/e23e8QoAAIB5sKmlcNImhG3pdXpsnIP1Y8MKYMrSPVHv47BO9fokNo7Ial6rxkYAADC5rrMUTr6OB/rY02YHLb3HZ9X+uV63ea1UtXWjx4vdvGedQXLHant50ONPXf/KeKCPtWJDpkeme3mt4rXQa9rrpo5XtHO51zZ5W/e4vk/rVNsAAGBCrO71qqV/+iuHY23o/A+7tJ0Z2qI65NW29Tqg2j+v2l4ejrH0+f/22i8ca+MEr9tD2xE2t8B2ijWBbSOvo6tjCtMAAGBCKZz8YaknaFno/CWh7Yrc3k+vx4gaD7Zz3tZ4sUHvMwrqrdJ1l/XaF1nvc+cS2E62JrBpjOH2eVsBt1ePJQAAmAD3WAoX78cDQ+oW2Bbm9uJErxmvl6q2j70We93t9aTX7rm9Dkq35G3N1NTEB1HP0gO5dN6o/Gbp2mfEA0N4wXoHNt2bh7w+8DrO63lrwrJ6yZ7zetHSeDVZYGlmr8651JrApgkP5Rq6P+oR1F+VKDQ+bGlyhHpSAQDAmPvL0j9/hYm2ugW2w3K7bGKpx624N/8tAUz0eFZjx+QQ6ww7Mfi8VW3fX23PN43Be8zS9XuNUetF4wLj547UW3a8petsZilUKegVCl5lRm9xjjWBbd1wrAS14mVrPrfGuwEAgDGnQfHPWAoA6sVpo1tguyy3i0KHxl5FdWCTaUuPQ/V4r19gU4+TliRR+63h2Cio50rrs20YD/QxZbM/d7E4/1Vg265q1+vvrPblbUvXL+rAFh8Xx8B2cW7Ta94IxwAAwJjaytJjS/V2tdEtsKm3SOPi5EivC6tjRQxsegyoax9o3QObls+Qo7zW8HqkOlY73+uVPtWW1qE7ODYOoB6znyyFqqhMqKjHo4m+yxPVvszk9qIObOo9q49poV/R2nmiYKveu6utM/QBAIAxpVD1aWwckkJDPYFAPWp3Weq1KxQYFB40G7WEHwW2El6utSZwHG6dQUS/viD35b9LLL2PZpPqFwlGSYHrqtjYghbV3c3Sd9/f69nq2NnWhCvZwdKvKayd97WsiIKpwm9ZIkVj2Q61NL5Ngay+Tw9aCrx6X3nT0mLA+g7vlBcBAIDxpZ9g2iM2DkFLcyg0qPQe+lkrDaKPFMw0yL4+pvXWrrfUq6QB9QpgotmOer+pvK+Aop6x0sP2tKXJBjpv79w2CgpJmpAxaD25fhTC9D0VxPRdtfiwvG4pxCrQafJFoXugfX3fEng1BvBxS+ffYOne6FGwgqy21dMoOlfj+8os1Au8HrXUS7cotwEAgDFVD+JHQ71SWjoDAADgP6OeIz26bLNo7muxYQLpEWYcwD/INbEBAABgPmiMVL0u2iD6/dFLYuME0ni8Y2NjH6d5LY2NAAAAc3WQ166WBqTH0uxDrfS/tdc+XjdbmpDQbUbmpJmx2fejvi/reW1haVzdtDWL12pCAQAAwLzRzEStK1YmC7SpSRe/7zCl2a5tHisDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/3f/AhSCN+OR+SdsAAAAAElFTkSuQmCC>

[image7]: <data:image/png;base64,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>
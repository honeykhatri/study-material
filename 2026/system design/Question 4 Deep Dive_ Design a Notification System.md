# **Question 4 Deep Dive: Design a Notification System**

A Notification System delivers timely, multi-channel alerts (Mobile Push Notifications, SMS, Email, In-App Messages) to millions of users globally. It underpins critical enterprise workflows such as 2FA authentication, payment receipts, social interactions, and promotional marketing.

## **1\. Requirements & System Constraints**

### **Functional Requirements**

> * **Multi-Channel Delivery:** Support iOS Push (APNs), Android Push (FCM), SMS (Twilio/Vonage), Email (SendGrid/SES), and In-App Notifications.  
> * **Notification Types:**  
  * **Transactional / High Priority:** 2FA OTP codes, password resets, fraud alerts (Sub-second delivery).  
  * **Informational / Normal Priority:** Order status updates, friend requests, system updates.  
  * **Promotional / Low Priority:** Marketing campaigns, daily digests (Batch/delayed allowed).  
> * **User Preferences:** Users can customize opt-in/opt-out status per channel and category (e.g., disable marketing SMS, keep 2FA and push enabled).  
> * **Do Not Disturb (DND) & Frequency Capping:** Respect time zones (e.g., no promotional pushes between 10 PM and 8 AM) and enforce rate limits (e.g., max 3 marketing emails/day).  
> * **Templates & Personalization:** Dynamically render templates with custom parameters (e.g., Hello {user\_name}, your order \#{order\_id} has shipped).

### **Non-Functional Requirements**

> * **High Availability & Scale:** Guarantee ![][image1] availability.  
> * **Low Latency:** High-priority transactional alerts delivered in ![][image2].  
> * **Reliability & At-Least-Once Delivery:** Zero message loss for critical alerts. Handle 3rd-party vendor downtime gracefully.  
> * **Idempotency:** Eliminate duplicate notifications caused by network retries or producer re-transmissions.

### **Back-of-the-Envelope Estimation**

> * **Daily Active Users (DAU):** ![][image3].  
> * **Notifications per User / Day:** ![][image4] notifications on average.  
> * **Total Volume:** ![][image5].  
> * **Average QPS:** ![][image6].  
> * **Peak QPS (Flash Sales / Breaking News):** ![][image7].  
> * **Payload Size:** Average payload ![][image8] (JSON containing user ID, metadata, dynamic parameters).  
> * **Storage Footprint:** ![][image9] of notification log data.

## **2\. Push vs. Pull Architecture Comparison**

| Metric | Push Architecture | Pull Architecture |
| :---- | :---- | :---- |
| **Communication Flow** | Server actively pushes payload to 3rd-party vendor gateways (APNs/FCM/Twilio) or open sockets. | Client application periodically polls the server for new notifications (GET /api/v1/inbox). |
| **Use Case** | Mobile/Desktop Push Notifications, SMS, Email, Time-critical alerts (2FA). | In-App notification center / User message inbox. |
| **Latency** | Sub-second (![][image10]). | High latency (tied to polling frequency, e.g., 30s–60s). |
| **Resource Overhead** | Very low client battery & network consumption; requires server-side queue management. | Heavy battery drain and wasted bandwidth from empty polling responses. |
| **Verdict** | **Primary choice** for real-time mobile push, SMS, and email delivery. | Used **specifically for in-app history** (fetching past notifications). |

## **3\. High-Level System Architecture**

                                    \+-----------------------+  
                                    |   Microservices /     |  
                                    |   Client Apps         |  
                                    \+-----------+-----------+  
                                                | (HTTPS / gRPC)  
                                                v  
                                    \+-----------------------+  
                                    |    API Gateway        |  
                                    \+-----------+-----------+  
                                                |  
                                                v  
                                    \+-----------------------+  
                                    |  Notification Service |  
                                    \+-----------+-----------+  
                                                |  
             \+----------------------------------+----------------------------------+  
             |                                  |                                  |  
             v                                  v                                  v  
\+------------------------+          \+------------------------+          \+------------------------+  
| Preference & DND Filter|          | Idempotency Checker    |          | Template Engine        |  
| (Redis Cache)          |          | (Redis / DB Unique ID) |          | (In-Memory / S3)       |  
\+------------------------+          \+------------------------+          \+------------------------+  
             |                                  |                                  |  
             \+----------------------------------+----------------------------------+  
                                                |  
                                                v  
                                    \+-----------------------+  
                                    | Kafka Event Broker    |  
                                    | (Priority Topics)     |  
                                    \+-----------+-----------+  
                                                |  
         \+--------------------------------------+--------------------------------------+  
         | (High Priority Topic)                | (Normal Priority Topic)              | (Low Priority Topic)  
         v                                      v                                      v  
\+--------------------+                 \+--------------------+                 \+--------------------+  
| Transactional Queue|                 | Informational Queue|                 | Marketing Queue    |  
| Workers            |                 | Workers            |                 | Workers            |  
\+----------+---------+                 \+----------+---------+                 \+----------+---------+  
           |                                      |                                      |  
           \+--------------------------------------+--------------------------------------+  
                                                |  
                 \+------------------------------+------------------------------+  
                 |                              |                              |  
                 v                              v                              v  
      \+--------------------+          \+--------------------+          \+--------------------+  
      |  FCM / APNs Worker |          |  SMS / Twilio Wkr  |          | Email/SendGrid Wkr |  
      \+----------+---------+          \+----------+---------+          \+----------+---------+  
                 |                              |                              |  
                 v                              v                              v  
      \+--------------------+          \+--------------------+          \+--------------------+  
      | iOS / Android Push |          | Telephony Network  |          | User Email Inbox   |  
      \+--------------------+          \+--------------------+          \+--------------------+

## **4\. Deep Dive: Key Technical Components**

### **1\. Request Handling & API Endpoint**

Services emit notification requests to the Notification Service via gRPC or REST APIs.  
POST /api/v1/notifications/send  
Content-Type: application/json  
X-Idempotency-Key: e4a3b890-1122-4a5f-a39c-9821a00f1234

{  
  "user\_id": "usr\_99812",  
  "category": "TRANSACTIONAL",  
  "channel\_preference": \["PUSH", "EMAIL"\],  
  "template\_id": "tpl\_order\_shipped\_v2",  
  "parameters": {  
    "user\_name": "Alice",  
    "order\_id": "ORD-88219",  
    "tracking\_link": "https://shipping.com/track/88219"  
  },  
  "priority": "HIGH"  
}

### **2\. Idempotency & Deduplication Engine**

Network glitches can cause client microservices to retry sending notification requests. Without deduplication, users receive duplicate SMS or 2FA codes.

#### **Mechanism:**

> 1. Every incoming request must carry an X-Idempotency-Key.  
> 2. Upon receiving a request, the service queries Redis using an atomic lock command:  
>    SETNX lock:notification:e4a3b890-1122-4a5f-a39c-9821a00f1234 "PROCESSING" EX 86400

> 3. If SETNX returns 0, the request is recognized as a duplicate and immediately rejected or returned from cache.  
> 4. If SETNX returns 1, the request continues through the pipeline.

### **3\. User Preference, DND & Rate Limiting Engine**

Before enqueuing a notification, it passes through pre-delivery compliance filters:

> 1. **Opt-In/Opt-Out Check:** Query user preferences from Redis Cache (HGETALL user:preferences:usr\_99812).  
   * *Example:* If category is MARKETING and sms\_marketing\_enabled \== false, drop the SMS job.  
> 2. **Frequency Capping (Rate Limiting):**  
   * Prevent spamming users with marketing pushes.  
   * Implement a Sliding Window Counter in Redis:  
     INCRBY user:rate:usr\_99812:marketing:2026-08-13 1  
     EXPIRE user:rate:usr\_99812:marketing:2026-08-13 86400

   * If counter ![][image11], suppress promotional notifications for the rest of the day.  
> 3. **Do Not Disturb (DND) Local Time Check:**  
   * Look up user's IANA timezone (e.g., America/New\_York).  
   * If current local time is within DND hours (e.g., ![][image12] to ![][image13]) and priority is not HIGH, reschedule the job in a **Delayed Kafka Topic / Redis ZSET** for ![][image14].

### **4\. Template Rendering Engine**

> * Templates are stored in S3 or an in-memory cache (e.g., Jinja2, Mustache templates).  
> * **Compilation:** Combine the raw template string with dynamic JSON parameters.  
  * *Template:* "Hello {{user\_name}}, your order \#{{order\_id}} has shipped\!"  
  * *Rendered Result:* "Hello Alice, your order \#ORD-88219 has shipped\!"

## **5\. Queue Topology & Message Broker Design (Kafka)**

Using a distributed event log (Apache Kafka) decouples API request ingestion from slow, external third-party API calls (APNs, FCM, Twilio).  
\[Kafka Broker\]  
   ├── Topic: notification-high-priority (2FA, Password Reset)  
   │     ├── Partition 0 ──\> Transactional Worker 1  
   │     └── Partition 1 ──\> Transactional Worker 2  
   │  
   ├── Topic: notification-normal-priority (Order Updates)  
   │     ├── Partition 0 ──\> Informational Worker 1  
   │     └── Partition 1 ──\> Informational Worker 2  
   │  
   └── Topic: notification-low-priority (Marketing, Newsletters)  
         ├── Partition 0 ──\> Marketing Worker 1  
         └── Partition 1 ──\> Marketing Worker 2

### **Why Dedicated Priority Topics?**

> * **Head-of-Line Blocking Prevention:** A massive promotional email campaign sending 50 million emails must never delay critical 2FA SMS tokens.  
> * **Worker Allocation:** Allocate dedicated worker pools to high-priority topics with aggressive autoscaling policies.

## **6\. Resilience, Retries, & Third-Party Fallbacks**

Third-party providers (SendGrid, Twilio, FCM) experience rate limits, network timeouts, and regional outages.  
                  \+-------------------------+  
                  | Dispatch Worker         |  
                  \+------------+------------+  
                               |  
                               v  
                  \+-------------------------+  
                  | Send to Vendor (Twilio) |  
                  \+------------+------------+  
                               |  
            \+------------------+------------------+  
            | (Success)                           | (Failure / Rate Limit)  
            v                                     v  
\+-----------------------+             \+-----------------------+  
| Log Success in DB     |             | Retry Counter \< 3 ?   |  
\+-----------------------+             \+-----------+-----------+  
                                                  |  
                               \+------------------+------------------+  
                               | (Yes)                               | (No \- Exceeded Max Retries)  
                               v                                     v  
                   \+-----------------------+             \+-----------------------+  
                   | Exponential Backoff   |             | Fallback Provider     |  
                   | (Retry Queue)         |             | (e.g., Vonage / AWS)  |  
                   \+-----------------------+             \+-----------+-----------+  
                                                                     |  
                                                  \+------------------+------------------+  
                                                  | (Success)                           | (Failure)  
                                                  v                                     v  
                                      \+-----------------------+             \+-----------------------+  
                                      | Log Success           |             | Move to Dead Letter   |  
                                      \+-----------------------+             | Queue (DLQ)           |  
                                                                            \+-----------------------+

### **Handling Failures At Scale**

> 1. **Exponential Backoff with Jitter:**  
   * Retry interval: ![][image15].  
   * Prevents the "thundering herd" problem on vendor APIs.  
> 2. **Multi-Vendor Circuit Breaker & Fallback Routing:**  
   * Maintain secondary integration providers (e.g., Primary SMS: **Twilio**, Secondary SMS: **Vonage**; Primary Email: **SendGrid**, Secondary Email: **AWS SES**).  
   * Implement a **Circuit Breaker** (e.g., Resilience4j): If Twilio error rate exceeds ![][image16] over 1 minute, open the circuit and seamlessly route SMS traffic through Vonage.  
> 3. **Dead Letter Queue (DLQ):**  
   * Messages that fail across primary and fallback providers after maximum retries are dumped into a DLQ for manual inspection, audit logging, and offline recovery.

## **7\. Data Models & Database Design**

Use a hybrid database approach:

> * **Relational DB (PostgreSQL):** User settings, notification preferences, templates.  
> * **NoSQL Wide-Column / Time-Series DB (Cassandra / ClickHouse):** High-volume notification delivery logs.

### **Schema Definitions**

#### **User Preferences Table (user\_notification\_preferences) \- PostgreSQL**

CREATE TABLE user\_notification\_preferences (  
    user\_id UUID PRIMARY KEY,  
    push\_enabled BOOLEAN DEFAULT TRUE,  
    email\_enabled BOOLEAN DEFAULT TRUE,  
    sms\_enabled BOOLEAN DEFAULT TRUE,  
    marketing\_enabled BOOLEAN DEFAULT FALSE,  
    dnd\_start\_time TIME NULL, \-- e.g., '22:00:00'  
    dnd\_end\_time TIME NULL,   \-- e.g., '08:00:00'  
    timezone VARCHAR(50) DEFAULT 'UTC',  
    updated\_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT\_TIMESTAMP  
);

#### **Notification Logs Table (notification\_logs) \- Cassandra**

Optimized for ultra-high write throughput (![][image17] records/day).  
CREATE TABLE notification\_logs (  
    user\_id uuid,  
    notification\_id timeuuid,  
    category text,  
    channel text, \-- PUSH, SMS, EMAIL  
    provider text, \-- TWILIO, SENDGRID, FCM  
    status text, \-- ENQUEUED, SENT, DELIVERED, FAILED  
    error\_code text,  
    created\_at timestamp,  
    PRIMARY KEY ((user\_id), notification\_id)  
) WITH CLUSTERING ORDER BY (notification\_id DESC);

## **8\. Summary Checklist for Interviews**

> 1. **Clarify Scope:** Distinguish between Push, SMS, Email, and In-App delivery. Ask if user preferences and rate limiting are required.  
> 2. **Justify Kafka Decoupling:** Explain why async message brokers are critical for insulating system throughput from slow third-party providers.  
> 3. **Detail Priority Topics:** Emphasize separate Kafka queues for Transactional (2FA) vs. Promotional notifications to avoid head-of-line blocking.  
> 4. **Demonstrate Idempotency:** Explain how atomic SETNX locks in Redis using an X-Idempotency-Key prevent duplicate notifications.  
> 5. **Discuss Reliability & Resilience:** Show deep understanding of Multi-vendor fallback routing, Exponential Backoff with Jitter, Circuit Breakers, and Dead Letter Queues (DLQ).

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAAAZCAYAAACB6CjhAAADqElEQVR4Xu2XWaiOURSGX/M8Z8p0KCQJF8gFDuUCUYgkUcpQCBdIyRglUS4MITORDMmchMyijGWeImOUIReK97X2/s/+t/Od853jiv6n3vrX+tZe3/72sPb+gRw5cvyDDKWOUzuoZtEzTwVqC1UxfpBEB1jSO9QDakr249+Uo+ZQN6j71DGqRVZEMnWpTbD8j6nVVJWsiHT586k3VG33+xOsr/UKQtCZOk0tCXxF0o36Ro1ydiPqBTUuEwGUofZS16hazqfOarCq+qAE9PGKW0eVhc3OUdgMetLmP0itDWxN2iRqD3UENmj7Ye0qB3FFcpt6FfkWU+9gnRXDqJ/UhEyEzeAPanrgK4xVsLZtA19f59NsibT5n1KLAnsFbAJDDlF9Il8izWEv1siHaPbl94k2OntgJsJ4SZ2NfDFa8mpbI/C1dr6Fzk6bX7ZvI+IBGAHLlZpOsBdfjvxjnH+Gsw84u18mwnhCfY18Mdqnahvu+RbOd9jZafOfgNUPj5a93/91qJuwLZeaJrAXX4/805x/pbPXO3tQJsLwH6eXJ6H9qJiagc8PvAqeSJu/P/Xc2fnUbucXG6iRgZ0aLf+4Bqio6MVKKrQ0ZY/PRADtnU9qGvhjlsNi2gQ+FS75Hjq7JPm1zM/AimYD5+sFWw2logvsFPCj15O6B3uxCphHg3IVVqVVHFXF37u4+kFcjOK1CtbAToGGsGNK7XQsekqbvxJsEvOcrcHaSZ2kBjhfsXSFHU0qOCosE2Ev1lHk0aViAayT2rs9qGfUd9gZXhSNqc3UJWoXrK3yq5Oe0uZXUfQnheJuUcNhx+AF2ICXmFmwDhY3glo56nBJUeVW/mXxg4ji8rejzqNggLSVNGBaaWIwCgp5IrpaalbCC8dWWAHylVujqRiNrKcV7CNmB77CUCd1gdGe9oyFte3u7NLk1+XpFKygerRi3wa2jltfxxLRzUkv0jYQ2oMfqXmZCKAjLCYsNHOpD8g+dsrDipRuk56psLYzA586fjqw0+YP0V1laeTTdggHQIW32AGYT92FzYLu2LpJnUPBLVBUpz7D7gdCW+ML/jy2JsM+RBXakw9rqxWgpap9/ppqGcSkze9R9b+CP/9PaAWFNWMIUmyBatQ22Pn6CHZsFXa/V6d0bX4CKy75WU+NPrCtE8620DJWO0mDk5f11EiT37Od6h07YZOoo3W0+30R2avxv0AFVH+sksij9sFOtKQV9E+j41Jnf44cOXLk+Bt+ARRU8YKCxBT9AAAAAElFTkSuQmCC>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGEAAAAZCAYAAAAhd0APAAAD+ElEQVR4Xu2YWYhVRxCGfxONa6LBICKIIhoISkBJYgQVjAuD4oMYhYARFA0huGRTTCRmHl1eXHB7kQHxxQVRlCzgggYSlyxiUMEoLigIcXsRH9zqs7pn+h6vOufOVXHmfPDj7Vt9zu2uqq7qUSooKCgoaMa8Yupq6pQ1vEi6m9plv2ymrDDdNd03zcjYnjutTD1Mc03/m94rNTdravQMg/Ca6RNT26yhDOdMJ0x/yhfUkoLQT88gCO1Ns01H5JlNljeWBWp5QeirKgahg+lr09+mr+TByMvLHAQabCVUJQg4/1u5879UZc6P5AkCJ+wH0y7TT6Y9pr9MbyZzpspP5H7TYdPHiQ0olUtMp0yHgmaWzJA+Mu0z/WE6Zlqmhj0OMZ0x3TRtMY0P//Ke46YPwrwIa54n/7298rnT1YQgROezccpPNW40eYKAg9lIpKfpuumtMOY0Xjb1DuOhpnumkWFM5u6XBycGjp7EbSW+Y6Lpqql/GNPntsmD0lrug0Hyy8QF00o1lF+CdjR8jqwyXTG9E8ZtTBtVQRDIgpj5OL8xjbex5AnCWnmWpydvg6mLqZvptmlxYgPmbw2fP5f/1ugGs74zbZI7+HXTNdPyxA5vy5+blXxH1t9S6VpYHwGNDJQ/xx5T2GvuIHAEybD5qk72p8QgvJ81lIFFM5fs3yEvhWQmTAm2s/KMjDotL1/wa5iDs8sxWW7/LGuQO/e3ZPyP/BSlkPU8H3tFbRiPjRMCFQUB2Cy1jR+fo+oFIwZhcNZQBo79Inkp4BlEzWZtlCLG2fqeQkCY87jbW3zHtKxBfsrOJ2MCQJBT+EOM518N4/VhPLx+hlNxECId1RAMrqNNacoQg/Bh1lAGantnuRMHyBsmNf8L0wT5exbWz36Ug/I5lK5yTJLb07ID9AV+J3U6tf9pQagN4zFxQqDJQYiQfd+o6TekGARK3tOo06MLp1HzjjfkN5YDpeaH/z+zOXyOmU7pSvlUXg5p1jdMq0vNelf+HH0xQhI+Lgj0F4g9Af+kcIPi+yed2lzgfH6E48km8waD8sKCRmQNZagz/StvxEBJpMTEU4QzyVjKJaeF2rzONC7YmU8GU1a4q0Mv+Y0pXjYoRQQCBwLf75RfQTkRkZPyBEwheOwl/Y+5NfK5JAlwO9oun8dVOa+/nggbpCyQiY158S9yZ9yRL4iaS1P9MZ2UgQ19b/rZtFvuPO7cKTXyBsq7f5cHJgVncK28KE8cGnyfkhneSNkH2Y4Dl8rLMAyTX1JYM7pkGiVfe9wLV1wSAXA6f9vwPhKCPkEZj8//F+YV5IBSg2OB08ZnviMJY8OnJ6SnJgu2al7zCwoKCgoKCgpaEA8AXR7q6XS9n2sAAAAASUVORK5CYII=>

[image3]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGIAAAAZCAYAAADKQPsMAAAEtElEQVR4Xu2YZ8hcRRSGX42KvUawYUMEe1SsoK5BwRb0jw0Rf6lRMaKREEExiB3F3lAIimBLELv+yooFS9SIGE3UBI0dK6jY9Tycmd1zZ3c/935fPhLhvvCyO+89d+7MnJkzZ0Zq0KBBgwYN6mGbUkiYYJxlfMv4kvFp447RIGGScZ7xReObxunGVSoWyx8PGj8zbpXK+xkvMd5kPC5pWxpnGq8zzkgaWM+4yPhC0FYY1jYeaHzc+GTxLON64wLjuqk81fiFcdOOhbS18Tvjqam8sXGh8eKOxfhgifEfuQPAZOPDSZuVtO3lffjT2E4a2Nb4l/En+WRbYTjL+LXxKXkj+zmCmfa78eSgMctxxBVBu934figDHPazcYNCX55gZR5RaMz06IiMN1R1BDhYvpJXGvyq/o44R96p3Qq9LZ/xAMd8ZZzbeepoyd89odDHG+uovyNeV68jVjoMcsQ98k6V+8djxr+Na8lXDTazKxbSnkm/qtD7YdVSGAKrGzc37m5cP+hrqr8jXlHVEYRlQureQauL0bR7RAxyBGGLTtHhiEeSTvzdJ/2/q2Ih7ZL0+wo9Y5rxE+MvxnPlG+kc42L5gG0mDzvEfAbxVVVXJvVSP2wFfVhHfKzu+xGscML2fOPL8pB2enh+gPEj44/ycZiSfmnfO8Z9u6b1McgR8+QNZVAiHkr6HsZD0v87KxbSTkl/tNAzNjEeL7dZajwx6Wz0OIeBu0E+MPA1edYWcaZG7wjwgHodcaPcCXlv20KeXV2eyqykvYzfyCfSzepmh3yDd0eNQY5o678d0Ur/6zoC4Axs2oX+nnyjZ1AzWHF/hDI4RmNzBCltdMRBqZxT34wz5KGYMJjB7GfCEJ4z7pBnYqMGjiAMlRgUmnKKuIMGh6adk35/oUdsKLchvYygk2yuEWRm2Ma4fFTSWkGr44hrVXVE/kZ5TiK7Qs+rApDSE7YiblFvG2sBRzxTivLBpeLtCp3NGp3ZgJP4f2/FortZX13oETnVLG3elh8MI26V28acnz1kLI7gu9ERuV9lf/dPeuwjTqDOCA6SZRtrAUc8W4ryswAVl5kFsTqeG740PhHK4HD5uycVegSHxGEdcZt6O3lk0lpBq+OIa1R1RP7GrkEDuS+xnewF4+KI50pRvlFx2DslaKSNbFRXBo0l/UEogwvkMZTwMwg5NNVxxGpB6+eIOueI0hGTU5kkIoIMD50wnEFoGuSI2MahwUu/GZ8vHyQQv7lnygM6U36y3qhj4WeJH4ynpTLXH8uMF3Us+oMkgIaTHUW8q974e7fclqwl49ikHRY0sh20OFEAfSAdjeC75cDNlttOTGX6RrpatpGEAruIPFnyddBQOFr+ge/lL0NCzIeqDjLL7DJ1N1CyqzKGAlK6tjzNpIGcDUbChfL7Kb7LqlsqH1AcmNvzqfFQec5PNoL2rfFseebGikOjD5caz0/P0ciwCJ/cpVFPrpP6aSvf47ton6t7VcJGe5784pKVyS8hOoPMCvtcH5eOtJt7r1wfbWAV/S+whrqxlDyc2M7MJPRljf9oPMu5Ou/wLlrOTvhFG6bObBPrxGbYcFLWN1IbGzRo0KBBgwYNGowZ/wKQWVHPlGoBYAAAAABJRU5ErkJggg==>

[image4]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAoAAAAaCAYAAACO5M0mAAAA10lEQVR4Xu3RL2uCURiG8QdWFItgmWVBMfgFBqKCMJYNFtFqNW1ZBJvfYMk/H0EMhrXlORAsJsEisjREDIpex+Mrj2dveKvgBb/gc+6iitxOSbwjjRCeUEdfj0wvODg2eNUjUwG/mGOGDlLq/VIeXffoV04CDrMY4AOfmOLtanEug6XYb22KY4WmN/CKIOHcetji0bn/qyX2Z6q4D26+wy9840HdGmKH5h87ZR53+EPYO1Jb7LCqbjLGsz7QCGvE9LGIIaLnzyXsUbssVGVMsMCP2PG9YB0BLp4o29YtcYYAAAAASUVORK5CYII=>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAXEAAAAZCAYAAADHVx4nAAAOzElEQVR4Xu2bB5QlRRWGfxGMGFAw666LIAYERDG7D5BjwiMmBBMGUFAQFA+Cgo6CKIqKCTGxK6JiRFFRgmyDgGIAI4IKrBIEBREz5vrO7btzX031mzezb99blvrOuWde367urq7wV9WtHqlSqVQqlUqlUqlUKpVKpVKpVCo3YnZL9sTcmbFOsrskWzs/saawIHe03DTZVLLzkp2V7MRkG8cELZsnW5bszGTnJts32U3CuT8m+3ey/7V/796eK0FlkA67XnYt+RgXuyd7crL1k9062SOTHZ/sETHRmNgw2WuS3S/ZLZLdK9leyY6JiTSaelpVHJfs8mT3aI8fluygZO9JtkProz3sn+zwZPu1PrhNsguTfSv41kTyMorsnaxJtjzZOzU47aqEersm2VvyE6sBpyW7be4M0C9cU+6TnbtBcyuZQJ2Q7KvZOYdG88Nk67bHCNxvk22wIoUJyx+SPb89vkOy85MduCKFgTj/RlaQCFMXn5BdT7qF/afGAoLhFe72tWQ3i4nGxLaamZe/JdsuJtJo62nUXCzLNyIA2yT7bOuban2LZO/AAN+0PliY7D/J/qLxDuSrihfljpa8jBz6CX2GwYy6+pe6046KByTbKncmXiB77tfzExNmQbIv5c6MtZK9VWuYiO+R7HcycaLjlESckf6fyXYOPmZtiEMcjY9MdkE4BkTkr8luF3y9ZB+UzawZGUsgQl+QdWQKnOXPuGlk73OZbMb6MlkjmAS9ZFfLZmG/SLYk2UbhPIy6nkYNK4InZD5EKYq48wP1izg8VraCuKFDG1qeO1tKZUQdUvdeh09N9mKV046S1ybbM3fK8v/0ZHfNT0wY8vuc3FmAkMsaJeKRf6gs4q+QvfSmmb+RzQqAhnaVTHgjPdm1O2a+I5Id3Z5jxM9hlriLJivi39RkVgAlHpNsae7MGHU9jQPCVCUR/55miviaQk8mysPCyo8yIuQ1TpapLOKrK4QPfQU6iF11IxTxj8peekHm/3Ky/ya7pWwWSJolfSmkLVo/SxinJxNxQgGcOzScc1gWEdtqNLyIr5ds69wZQMA89joMp2r1EfFHa3YRH3U9dTGf1cg6spnbg9QfsyS+XxLx76hfxAn5EQbaMvjmynzy7azMtZFNZKugkojPVkb7BF9X2lHA8w6QPbMk4qzW2KPhXebLqMrTuW+yz+XODuYj4uSXMncoI/SE0J6H927e+iZKl4gTauGl8+UThYZ/UbKHtr8/1JfCZtn4jwm+nkzEefkrZUvL+PJ3SvaZ9nej4UWcQjxJthlZ4r0aHIPPOUW2mUTsj5khm4Qr03BXhkfJ9iwoXwaXn2nmzGzU9RR5pSwmSxyeDVU2HT8vC+00svphaU+MGwE+R/0rAu7L/bFe8A8r4r/W9PUR2g0hwe8nO1sWhmG57LAJfVGy62Tl8JT2L/n7icoxX4dO64LL6oW6PzbZybKyKMW1t5HNYMn/j5K9QzZ4AqLBva6XDar8xihbKJXRTm0afJQ9v9/UkdZhwGeDjzbybdmEyNvE2rI9B1aZvAflRZiG2b7z4WTXyu7NHgTPJKQI90/29/Zc0/ocZsG+J8NzG9kK0ulqQxfK+i0fEDjs03xMNgHhHH9p911MJXtm7pQNOEcl+1Wyr8gmL4fI8h9FnHZCf0f/TpeVDz6HCcSlmi7z38tCgfQn9mrw/VnD6dQqpUvEaZRkMs8gQot/s2SL298UWISvKfDzVYfTk4k4IKyczyvbK6RR+dldULBsSLJ5GjlMc99Np/G8S9OzBir/imR3W5GizOtlDXlYO84uGwgNigGP8gQ6JXsZU55Ao6+nyB2TPUuW5pJkz279dDY6JaL1bpmoYt+VLW8j7ClwfS/4hhVx+LQsbYR2hIB7LJ+6QRSoK2AG/2CZECEgtDefMPAMru2CdAg3gsg7IiQ+632bbP+B93eeIftqw8ODCCNhK+oF8XQQLvJTYi5lVErLQEq+ntceM2iRhi+AwOufwQjoLwxmH2+PnQfK0u2Z+YH3YlBtgo8JFOXJ5MD7CxMPhI08wWxt6PD2GAi1viEc8x4/Dcc5tDcfLB3yxOTrjGS3b31MEBlcyUMUceoI30btMQM0gxWDVoR+Q7p7B9/rZBODOFOfGF0i3sgyPkgceu3vYcShp2kRR5w4H2eGjLheIY3Kzx4EjYKZVq89pjG8b8XZ4aECvUECFUdePO/jhNjxosxHx6POvGwalctqvvWUQyckTZP5fy7bFEVsHOqTLygi28uu7wVfl0CVRJxOTlqHgZ/jHYIPXiqb6RJqcBAqhCJ2dDbXmUXNBm0nzzcChI/NVkAM+eInbxsby9JFMRwk4nMpozwtK1tmi3HwXJjsG5qe1CA0u6pfwJjZUw6xbAaJODD4NeH4QFmZ00Yin5J9BomgwqA2xGAZj98fjuGL2bFDKNAHpcirZM96eOZnNY4/lgED/c6aHuApS94nDy/yJRDXsonq8I4+cE8cBIEleU7XMt0/D6MwupbpCCH+WMg99Tf2i2UdgBGeex0TzjWy63Nhmg1GXBoaDYFlmVfOykDFkhdCCKsDB8vy4zvyo66nHGYzpGHJHEEgmfFEjpSljYPgk1pfL/i6BKok4m+XpXX8GQhlBGHFf0jwseIhdBBxcY55LEFbJR1C7TDrxrdNe7xje8wAkoNAnhmOB4n4XMooT8tnwqX6yUGsXyILs7BqXS67jj7jzCbizHybcHy+bJWawwSK+zyuPR7Uhs4Ix7RD0jHjRw981l6CVREDWk4juwersUhJxGFz2WpymSwvpKGN5Vwgyy8wuaIMVxsQceK/OXR4XiguIYDlJX4aBcLB73xZ5htmFLTT0/TyDg6VpeHTqSlZ43Sa9txcRRzoxCznEK65Qlz9T5r5tQajM3HCcUNDQYTiN9LeQTzOP+p6ykHESmlYnkaRAgZP0sb8sqzG1wu+LoEqiTjPJa3j75W/LzOv/B0pO+4ZoQ3meSyB4JAurjSe1vq2bY991scyPId+hRg5g0R8LmWUp31uezzVHpcg3IQAES8n3MHk5iDZdXcO6WYT8bx+rlP/Ozr7q79cBrWhKIaExxByj79jbNyXOFfl/90grEZ/zSmJ+D6yT6ynNB0iY/BltZZD+ITrWdkSttq3//RkobGx9MrZXZbpLTM/yzZGJedK2eZBZDvZtTsFX08Wm3Q2laUhrsSGSIwtNe25uYr4HrL7sSFBg8tjW7MxJXsu8W2HER3fL4OvxAGyVcCw9km7rBNEhgbGoBKXvD4zpfPCqOspZ111d8BcxD8gSxsFkiU9vl7wdQlULhJwmCyt489AcCL+LjGflPN8RfxwWbpBIu6x3lz0EBeEJD6blRErT4e4uVMqI+q8VEZ5WvLCcWn26CyVpdkk+HwygIg/pPX5ysw3XelPPpuGc9RfPwwKV4djh30o7sOAA4PaUBRxvkMHwjCsME6UXZeHLRiwu8S9kV3joRwnF/ENZf2LPZcI9YaI31P9qxQ0hXNsWqOXs+2RjRVE/KTcKcskL+liAQgtlcYs2qHx5AL3alks0jcWoKeZMWo2LRj5jsr8jazA5yLiu8hi+z4YLJANDlTWsBBnZaYXO7jP8PI42ThgtrFV5qMBsSrwOOSo6ynHl8KlDtgl4msHXy46wHIU31TwAeGZJvPlIk4og2MENILw4I8rMMIpXSIe81jCwyklEXdhW0/2z2u8d4S4POl8tQQM2qR1+BLCKZXRsCJO/q6S1W0MHyJiDERwnmaKrZcDfczrcaPWxwwVmJgMEvE3y9JvEHxAHJvnedkN24YuUf8/szEYMiunD0YIf8R8Rcg7zyJMEtmv9fv9iQBwHAdg6hMfesQqywcV53TZFyqlSe/EoCFfL8tcCZaUNADv5PvL/hOQl3X4BpnGuUt7TIVeKmsADqLI8q1Rf6yKGS+Ftjj4gMaCf2Hm74JYJaN27HBAhSHk5HEY1pI1KnbFgfembIj9xdjouKChMTB5+fOeDHq7rkhhjKqeStDJqQs6ToRZWB5v/ogsbaxj7yyx07FsxhcHGeAdzs58PJe0UXSXyNKu3x7zbhdpZh7ZKCNdxAcaZoeDoCOTjrw6PvPePvgIGVCuW7THiOcJsjYcl/sMmFzLbJgNNUTUGVRGzGojpbSE/5glHqzpWD8C6+2EZ9FufGXKwM8eD/dhFn5y66efslo4rj1mtRBno0wqoujy1Q5CTH14/SyWCS9t1RnUhlgtOctlsXB/h41lA1SsK86Rj66VFOXP+WM1Paix2uBzQ/JA32aSQxmQT39XOERWl6zm+c0+S2Q32T1emPknArFfGv21skxhV8peNHZ8CorGQDyNWRKCkscigUbZyDY+6DR7hXObyWb7/hw+hWJUhEWyJb8XNhV4XZsOo5AZ0bsqDIj3ki9mLiVYiuVLpkHQaElPWVwmW7a5WEyCnZL9WCa4lG3sHM4o6qkEM0k6NXXBbP8SmXiQF68jymhrWWwUocB3TbKXy76QYaaPj7b2RtkMh/P4+JKF+mfpzH38ntyfvPI8novvCk0vz+nIe8s6KyLC393bc8AXLKT3+10uyzeb6X4/8uBhgwjCy3Pju5Dn42Vf4+DjnZhZO+znnCGb+TNwEPJitRGhfSKKvBthLZ+9dpWRlzv9hXzz7qW0zuNlExbSniW7h8Oz2a8gXny0TNQZ+Ei3XPaNuYPI8f6I6x6tj/qhDHkugwXPcJ3gL+LMqho7TdMbvzBsG+ILECZMTEBOlW3YnyJ7dgRh5V0GQR9eKhucCOFiRAH8efRp2Fb2njyPCcjOsv6FBi3VzA8jmCQR3pzEhK5SmRcImg+gNGhWOsy4mMm4j9/4OOeNnmu4Fp/PqviLb5h7epp4T9L4bG828vsNymOJUrro413ymOt8ma2MIqW04yAvT949F7guhqlvfpfetwQrqTjoDAurw2Gf0cWmGvwlV6VSqVQGgAiz0hx2AFlZGIBYERBGgSPUv29RqVQqlTmwtezrkHFBGJXwyxLZXobvHVQqlUplHvCFFXsl44Svo9ikXib77LBSqVQq84Rv7SuVSqVSqVQqlUplAvwfjX9eRKC8uGMAAAAASUVORK5CYII=>

[image6]: <data:image/png;base64,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>

[image7]: <data:image/png;base64,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>

[image8]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEQAAAAZCAYAAACIA4ibAAADBElEQVR4Xu2XS+hNURTGP8r7maI8EkJJeWTiUVKUQhkIGUhKmSD/oQH/CJmZUJ4hUWQizxj4e8sAxUAkSd7vkvfr+6yzu/su+5x7M7gMzq++umetdc/Ze+21X0BJSUnJ/0lXahf1inpCHaQGVkX8yWnqA/Uz0w/qLdUjivnq/AupMdTLyPedekE9p57C2nCcGot/RCuqhVpMtabGwxr2jOpTCUui+Luwjo12PjEL9p7ZVAfnmwH7305n1zevU19gMQ1nKnXG2TSSauwOZ09xCxY72Nl7UVepUc4emAL732bvQMV3xzsawWrqG9UU2frCGqTpU4tUQrpR52HVlkfo9CbvgE1X+TStVIV10Ynq6Y0J2niDQ4nQx/dGti6Z7V1ky8MnRFND64s6XERRQjTF5DvpHSk6wxqvUf0EK6sFsLXAo+yu90ZHW2oeqpOrkVWDLka2POKE6F3qxNaqiDR5CRlBPaSuwSq1JnpBM9UdlgQ1/iis8VrBY5ZRS52tHrbDGjvHOxKEhAyjDlGfYbvPgCgmRUjII9iiLp2jXlMnqP4hsBZ52Z9G3aYuUXtgGdaL28VBdTAcNnf1jnoICWmBTb8V2fPhKCZFXoW0hy3m72GVW5Mh3hChKTIBtkv8zT7ekboJ60yttScQErIye9a00cDINj0EJchLiNAgakFXtQ11viQq5bPUDWoj1bvaXcUibyhgH3UE1ql68YuqmJzZ7sFGPEVRQoQOh/Kv8g7PfOoKLCkTYYvmA1hVeFT+a70xh+XUKVRPsS3R7zxSCRGhQ2ucPVArIfth/nXe4dGH/KmvH3UMNo9VpppWc2HlP6gSlsskWMVpygQ0spej5zzyEqI2aR3IK/uihKhCH8P8RWeZ3xTtGqoaVY/uBlqxx1W7k2g1V/x9WOckrQE6viv5RWiX07avho90PrEb5rsAOzfFzMx8vgp1FzqQ+bY5X0PYAPt4SkVnGFXkG1RidffQvSVc7pojn6RK0e7hL3fhUiibBuYjbFCWIH22KikpKSkpKWk8vwA+hM90N+apFwAAAABJRU5ErkJggg==>

[image9]: <data:image/png;base64,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>

[image10]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEkAAAAWCAYAAACMq7H+AAAAnElEQVR4Xu2WuQ0CQRAEG4fjiehCIQUknuMLEBfxREEc9Gg5oUVowcPYKqms8UqzjwQAAFA7QzuzzfsApLFd2JNd2UE+rpuJ3dir7ZRiwZOIs1OKsxZxMvo4F6XjNcrHdROb0m9OxOFi/kBr7/YgtqdIHLW9vdmliFVkqleseO65tAvEZm3FC/cTEScincVf6StxR83tUYQCAPgbD0EPExC6lgINAAAAAElFTkSuQmCC>

[image11]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAZCAYAAABQDyyRAAABZElEQVR4Xu2Uuy8EURTGP/EIIR5RqWwiSDSUCkJoJAr/gkLQSxARUSsUKoVCiE5DIZ6FaMUreqJTSohCgu/kzE7OnczMzgzbzS/5Jbvfubtz7sy5A+TklI8WukXv6AM9pr3OijJzSae8z5X0in7QLn9FGSnQH/pssnkvWzeZzzA9pIOBPCut9I0+mmwR2sCayRzaoc/slA4FalloorXm+z60gZKb7KDb9Az/04gwTr8Qs/swOukOPUf2RuR39/Sd7tJqt5yMbroHbaTk7Yugjl5Aj2NboJaYHnoEnRH7bJMyAp0B+Y/UNNNVekMnnUo49XQCuvMiBWgD37TR5LHIJK/QW+hLpcotR7IJvdiGyWSmJBPlmMYiHS5DX6MzSD88xQYWTDbmZTKUkTTQJeiOZ2mNW05MH32lo7QCOjNyrD/pgFnnIwvm6DV0x1kvbOmnJ/SFPtEDaGOhSFfTSH+rc3Jy/swvSCQ9Y/9+E3wAAAAASUVORK5CYII=>

[image12]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADoAAAAZCAYAAABggz2wAAADA0lEQVR4Xu2WWchNURiGX2TMXOYpkjJPuXHjZIgbuVCGJLkQJWW4oVwgU8olEfVnLCQZL9z8vyJFIXOZLlwgs1Bm7/t/a29rf/85Dp3jQu23ns5e7/rObq21v/WtBeTKlet/0VRynbwPvwtIo0wE0JbUkJfkCTlM+mYiqqMmZA25Si6QM2RAHBA0gtSS8+QKWYGGY85oIiywC2wy28gPsj6K0QvqyELSmIwlT8kz0v1XWFW0lVwjrUN7EWxhO6URQG/yiswN7Y7kNlmdRhTRRTIuamtFH5DvpFfwJsNWL9Z82ILsdn4l6kk+k9mRp0XWRDdE3nZyN2pLWpAPpJ3z66VJfSMPkQ3YBZuEvqC0lnwly9IIoAcsRoOolhbD3jnU+XWwLyZp4sqko2mvqQD77wzn10tp+BoW0D/ylT7ykonpV+19aQTQJnhvI69SKTv0zj7OPw7LsJawr66YmkwEMDL4m5yfSgGTnHcW9qfEbwZLp3ifaJ8qRgWjnCbAikc5nYa9s5vzjwS/HxkTnndmIoDBwd/r/JLSRv9CbsG+eCkl6V00VSIlA1C1LqdaWGxX5x8K/nBYPdHzjkwEMDD4x5xfUgfJOzLMd0TS4LUYe3xHEXUmj8gJ31FEdSg/0UJ4rmiiKteqXAXnx2pFbsD2TVPXV6lKpa7ObPmqI6VSd1Dw9zu/gbRaL8h43+F0gJyE7dtqS4PXYP1FRIsqX8VIi6Bnn01JMdrs/Ix04N4hUyKvQGZGbWkprFA1jzyfQpVIZ6EGO9r5KnjxuanLihY7lgqn/jvL+al0luqaNd35OjunRe0COQdL3UQtYBeOctLt60+qrm5ZOq/nRJ62hzJtY+TpwnAvakvLyUfS3vmptsD25c2Aqu198gmW95Iq8XNYUUnitMJaWe2f32kIbKX/pOpKOsN1z00GvBJ2KemQRthZ+obMC20de4/JqjTCSTmvQRRDB7S+mKS89/0J8UoX099UXUkZtg5W8C6TU2i4Z6VRsCp9CbYwSzK9uXLlypUr17/VT5LxuXUoZwSxAAAAAElFTkSuQmCC>

[image13]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADoAAAAZCAYAAABggz2wAAACp0lEQVR4Xu2WWahNURjHP6SIMuUaMmSM68oUpZRjihevIsmr0n1x7wPllpSpiIgoJVJCyPigdO8DDyiUDCUUZShEoUj4//u+vc9aa+/jruMcD2r/6ldnfes7e317r2FvkYKCgv+FqbAdXod3YAvs4mWIdIUb4SPRnKtwmpdRH7rBTfAuvAGvwPFughFTs8cI+AGusnZ/+FD0plx2wJ2ihZA58DUck2bUh13wHuxt7TWi4wxMM+Jr9jgAHwcxXvwL7GNtDvpJdFZdDsFtQawWhsHvcIUT4yzxRrc4sZiaPXiRt/BMEC/BX3CZtcdZe3KSYHCW9wWxWlgr+eN0iM4Yia3Zg0+QnUeCOPce48ls9YLfRJ/sYov1hE/gXGvXg8Oi444M4ufhT9ExY2v2mCnaySXoMsnix5zYdotRLp1rsNXp/xMLRA+Pzrgsev0hQfy0xUdLdTWncDbYeTCIT7T4OSfG/cmnmNwsZ3eW01+JpID3YUcO7aK5g4P4SYtPkepqTilJ/J+Wwqeim/6F9X+Fs52cPBrgc3gh7MihQzq/0ZL9jqk5pdIyaLT4cWtPgJ+lfEj0hacsh6+CelFp6SZjjZX4mj14QXYeDeLJxua+JHvh2XJ3yn7RPPcdVwssntcbFcR5GDHOwyi25gxv4MUgtkj0T8utzSe6u9ydwplm3qCw4y/htuD1ZgRxfiG5782YmjPwBOVrwmWd6P7jEiVt8KZkP7HmSfbFncdCiTt1h8IfcKUT6w7fwa1OLKbmDHwvfYSrrc1l+BJuSDNEBogeQHtgD4txvz6AS5KkCjSJPumYU5fwE5DfuUnB60VP+H5pRlzNuUwXPfFuiQ7S7PUqw+EJ+Ao+E11O872MfKo5dQm/pTfD+/A2vCTZPUtiai4oKCgoKPhX/AZbOLvb8foB5QAAAABJRU5ErkJggg==>

[image14]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGIAAAAZCAYAAADKQPsMAAAEqklEQVR4Xu2YV6glRRCGfyMmjJjDXXdVjJjFyI4J1xXxwYCisk+CIvqgIkYQMYJZTKAuBhAVd80JdUdQRMUApjUnMEfMYqqP6jnT3XfmnHvOvT6I88HPOVNdE7qru7pmpI6Ojo6OjsFsZVpgesr0oulE0yKJh7So6QzTG3KfR01bJx5Tw2Kms0wvmZ42PWjaKHZoYCw3DMFepk/k922CsfnO9Ifp7/C7duKRsq/cD/0mP7ft2gnrmb4xHRmOVza9Lh/0mAtNF6m+6K6mT00zeh5Tw8Wml03LheOj5fdZtefhLGPa2XSv6f6sbRhukA/annlDBgP8kdz3pKwt5hb5+OE3LW3qz9WmhZmNzv9kWiEcMyjfy1dFzHWm8zPbZFjH9LvpsMjGyiQQ50a2Y0xfmB6Qz9BRA7G46Wv5oDEO/ShM18hnOKu1CcbpLlMpv+YaSWsf6OTn8pNjCvmFDgnHG4bjLSqHAKvkysw2GY5V831K+Sxr4leNHgjS0hOmv+TpKZ9oMYXpMtON8mfcLGl1yCpzNEIgmIGcMDezk/uxV7N9WXm+Y2buE2xLm942zQzHU8H18vuOZfZ75IPFPXMmEwhm+IHyvYj77pI2JxTyQOwt9z0vaXXuNi2vEQKxvfwEUkwM0cZ+c2S7INgQy/hx9c+VMeRfNr1BkGq4/pqZ/c5gn57ZYdRAMPvfk0+yE+TXvyTxSCnkgWCP/Mz0gdKCZjXT7eF/qSEDwWzmhGsz+ybBPj+y8eBzgx2xOnaI2tuogkouHsQCNXeADmLfMrPDqIGg2GAGw/ry639YN4+jkAcCrpD779ZrlY43HRT+l2ruRyuFJh6I/U3vyjfyqnr42bRT5NMEM+V9eXUziFLNHfg3AnGp6Yjo+AX5PcgSTRSqA0Gf8Y0zyWOqU2ep5n600paaNg32W8PxxqYfVW+iK5ruCD6UmlNFW2qq7rVBZgcCwXnD8pbqqhBOk9+DAqSJQnUggLRG2b+k/LniNF5qyEDQYU64KbNXmzX7ArAU59XNPa6S++U1/qgwIbgeqSKGzRp722b9UG4cwLby4oNcX+lL+T3eifxiCtPl0TGbNf4HyF9AZ0dtZWibcCCAh7gvs1WVwaHhmBnJUs5hpeC3et4wIqQ9rsdAxVDVLMxsFQTi4dw4AKrBo3Kj/KsB928qLAr5hKwgO+BLIfGMaYmorQxtQwWCCogyNIYqgvxPCoIzTc9q/GeP3dU+QDHU602dy1lL/oJ2eGSjg1+puVwEAvFIbhwA7yRNq/gc+QDym1No/DvTq6Y/NX6PLTVCIHiX4G1xTjjmAT82ndrzkFaRb9DkyKWCjRnxmmlW5dTC5vKHmkjVBHzi4M21mgSnyCu0lXoeNbwZk2KezBv6cLA8DfEpJ2dH+bO+qfT7EP+ZjKX800rF6XL/mZENmLTYp2X2gWwjv8lz8kE4Lml11jXdJn8DZaMiXeyReDQzTNUEdPps0yum5+UVUb5n7Cev4L6VdxiRYsnvTQGDMaX+BHC7qJ2Xux+idiYnHxyp1Fh1lZ1PMCeHc3ivISNUmYINm09Ble8v8tU8oY9+/xd4D6LC6ejo6Ojo6Ojo+E/yD2sqLQpBOtKsAAAAAElFTkSuQmCC>

[image15]: <data:image/png;base64,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>

[image16]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACYAAAAZCAYAAABdEVzWAAACS0lEQVR4Xu2WS6hOURTH/96vlFdI5BoQRow8Ji5DIo+SDMyEJBkYXQMhMpGRJCnlkYTI+9X1LjKhJI+SECYkA0r4/1tnO+usvu9856o7O7/61dlr7/Odtc9ee58PqKkpZRm9Qo/ScaEv0Ycepn1jRxnjYyBjLV1AR9BBdDY9Q2e5Me30Ex2SXX+lG+jwfAim006608WaMhD2oHP0fOhL3KF/ghdQnLXu3+/aenPr6Ul6kV6GTeYl7e/GNWQd/Qx7yC80T6yTPqfv6F26hvb0A8gbut2199AZri30+/NCrCU/0DyxG7QtBgPv6TbXjomtoIdcuzJliV1H68Su0n2ureVL9TWUPqHD8u7qlCV2jW6kl+gj2EMnF0YA8+lbWBLt9ITrO0hXunaXKEtMhaylSXW1g36gY/6NMLRct+gpOjKLzYFN5L8pS2wqisU+AbYz97pYI/rRx8jLYCw9BisNHT+VUGLanVXoBUvsRewIaDNsyq51z1O6HHZc3Kejsr5SlJhqKKKZfYP9oOc3/R5inin0HiwhsRD2jPTml9DN2XUpukmHYGQr7O10uJgOZcV0WDaiB71Jp7nYFtiZmZgI2xQtUWIq8shiehb5zMVMWGK7XMyzmu4OMS2rT2wSKiTWm/6E7aiIXr1Oey2F0LdQ457RwWmQQ7vxIR0Q4ioFTT5NcClKllL185p+Qf4N/Ehfwc6jhB52PIvrs6SZ6oPeiCN0bgzCCl73r8quH9DRhRHdiD5BB2LQ0UZP09t0UbGre9G/DZ1dNTU1XeUve4d3JSeJVEgAAAAASUVORK5CYII=>

[image17]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADIAAAAZCAYAAABzVH1EAAADMElEQVR4Xu2WWahOURTH/xKZMkamuMZCMkUJ3VPywIsHkiHdFw9KPCCRIZEhpQxlKJlfkMzyoO4pJGTIlCiJB0MSMmf6/1v7fN/6zj3f9d0XT+dfv87Za62z9157PECuXLkqUR+ymAwgzUgPMp8c9EFUY7Ka3CZXyHnS3wcEDSW15DK5RRaRRs73nvwkf8KzW/BlaSIsTnyHfat+ZGo8isEJX8gEH0RtJndIq1CeS16SjoUIG4R3ZHYotycPyYpChEkdfA5rS4NYTodg3yuuqtRVVxF5S56Rx2Qf6ef8Unfyg8xwNo2yElnnbDvII1eWlPBn0sbZIrITNsKa4SxpwI6TGJZI5xJvhsaR/WljSvNglQ1O2WPYiElK7DWsca8I9u20lG0L2Rt8g5wvkWa1Bg1IZCz+ncgeWGU9U/ZT5DdpDps1xWhGvYYF+wZni2CJaPnKt975Ep0krdGARMaQ02Q3uUgewDao1zlYZV1S9mPB3puMDO+qx0ujLbs/PCJYItq4r2DLOjkQpE7kSHiPUWEio2GV6dSS1Nk3sBMqUS2yK1Njsg8h1eF9V0mE1Sv7CWeLYIlI22B+LfFEC8jU8B4ju+06agkbUa8D5BuKH8fIrswnEoX3hiaigUzPpFaGlqsUI7vtirQW9vHMUC63tI4Ge1+UX1oDg/2ws0UoJiI9hR3bTWF1+WUYo8JELpGbKL1oVsE+Ts54dU7lXoUIkza77Bo9Jal3zaZXstk3OltEtrqyNrtiJsOW9CTni4Ov3kTUed2uH1GcSmkT7ONZoay7QOURhQiTbnh/b2ivnXFlKTmZpjtbBNsbiXSsK0aHx1XSxPni4Ks3EUm/EaNStgvkE+kQyl1hCSeJSWpMF6k/OnUhPnFlaSHsT6Gts0VkuytL98kv1N1jMSpMRNN5FsWGpsAqnFOIMOkXRbdwErcUdrO3K0TYXaLbuiaU9fvygiwrRNgqWAnrYAtnXw7rcLWzSdeCvSplz5Sm/S6sUXVWyaSlDqwh98gNWPLpPSMNh3XyOqwu/YAm0umm01AdE/rtWRJ8Ojm1TJP7RBv+Q4gTX2EroOxPY65cuXLl+q/6C/pe0vApLTIxAAAAAElFTkSuQmCC>
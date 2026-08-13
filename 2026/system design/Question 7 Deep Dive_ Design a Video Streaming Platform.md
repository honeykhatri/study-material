# **Question 7 Deep Dive: Design a Video Streaming Platform**

A Video Streaming Platform (e.g., YouTube, Netflix, Twitch) processes and delivers high-definition video content globally. Building such a system requires managing massive file ingestion, distributed async encoding pipelines, adaptive video delivery over heterogeneous networks, and caching petabytes of data at edge locations.

## **1\. Requirements & System Constraints**

### **Functional Requirements**

> * **Video Upload:** Content creators can upload videos of varying sizes and formats (up to 4K resolution, several gigabytes).  
> * **Smooth Video Playback:** Viewers can stream video content seamlessly with minimal buffering and fast startup time (![][image1]).  
> * **Adaptive Quality:** Streaming automatically adjusts quality based on the viewer’s real-time network bandwidth (1080p, 720p, 480p, 360p).  
> * **Video Metadata & Analytics:** Track video views, like/dislike metrics, and playback progression (resume watching).  
> * **Multi-Device Support:** Playback compatibility across Web, iOS, Android, and Smart TVs.

### **Non-Functional Requirements**

> * **High Availability & Reliability:** ![][image2] availability for video playback.  
> * **Global Low Latency:** Sub-second response times for video playback initiation anywhere in the world.  
> * **Massive Scalability:** Support petabytes of video uploads daily and millions of concurrent playback streams.  
> * **Storage & Cost Efficiency:** Cold-storage tiering for old/unpopular videos and hot CDN caching for trending media.

### **Back-of-the-Envelope Estimation**

> * **Daily Active Users (DAU):** ![][image3].  
> * **Daily Video Views:** ![][image4].  
> * **Video Uploads:** ![][image5] of users upload 1 video/day ![][image6].  
> * **Average Original Video Size:** ![][image7].  
> * **Ingress Storage (Raw Video):** ![][image8].  
> * **Transcoded Storage Expansion:** Encoding into 4 resolutions/codecs expands storage by ![][image9].  
> * **Streaming Bandwidth (Egress):**  
  * Average video bitrate ![][image10].  
  * Peak concurrent viewers ![][image11].  
  * Peak Egress Bandwidth ![][image12] (Terabits per second).

## **2\. Overall System Architecture**

                                      \+-----------------------+  
                                      |     Client / Creator  |  
                                      \+-----------+-----------+  
                                                  |  
                     \+----------------------------+----------------------------+  
                     | (Upload Stream)                                         | (Playback Stream)  
                     v                                                         v  
          \+-----------------------+                               \+-----------------------+  
          | API Gateway / Auth    |                               | Content Delivery      |  
          \+-----------+-----------+                               | Network (CDN Edge)    |  
                      |                                           \+-----------+-----------+  
                      v                                                       |  
          \+-----------------------+                                           | (Cache Miss)  
          | Upload Service        |                                           v  
          \+-----------+-----------+                               \+-----------------------+  
                      |                                           | Origin Shield /       |  
                      v                                           | Media Storage (S3)    |  
          \+-----------------------+                               \+-----------------------+  
          | Chunked Upload Storage|  
          | (S3 Temp Bucket)      |  
          \+-----------+-----------+  
                      |  
                      v  
          \+-----------------------+  
          | Transcoding Task Queue|  
          | (Kafka Event Bus)     |  
          \+-----------+-----------+  
                      |  
                      v  
          \+-----------------------+  
          | Distributed Worker    |  
          | Transcoding Fleet     |  
          \+-----------+-----------+  
                      |  
                      v  
          \+-----------------------+  
          | Production S3 Storage |  
          | (.m3u8 \+ .ts Chunks)  |  
          \+-----------------------+

## **3\. Video Upload & Chunked Ingestion Architecture**

Uploading gigabyte-scale video files over unstable home connections requires **Resumable Chunked Uploads**. Direct uploads through standard web app servers lock server threads and easily fail.  
Creator Client              Upload Service                API Gateway / Auth           S3 Storage Bucket  
      |                           |                               |                           |  
      |--- 1\. Initiate Upload \---\>|                               |                           |  
      |    (File metadata)        |--- Request Pre-Signed URL \---\>|                           |  
      |                           |\<-- Return Pre-Signed URL \-----|                           |  
      |\<-- Return Upload Session \-|                                                           |  
      |    & Chunk Matrix         |                                                           |  
      |                                                                                       |  
      |------------------------- 2\. Upload Chunk 1 (Bytes 0-5MB) Direct \-------------------\>|  
      |------------------------- 3\. Upload Chunk 2 (Bytes 5-10MB) Direct \------------------\>|  
      |------------------------- 4\. Upload Chunk N Direct \-----------------------------------\>|  
      |                                                                                       |  
      |--- 5\. Signal Complete \---\>|                                                           |  
      |    (All Chunks Done)      |--- Verify & Assemble Chunk Metadata \---------------------\>|  
      |                           |--- Publish "video\_uploaded" Event to Kafka \--------------\>|

### **Key Technical Patterns for Uploads**

> 1. **Pre-Signed URLs:**  
   * The client requests permission from the API Gateway.  
   * The Gateway returns a time-limited AWS S3 Pre-Signed URL.  
   * The client uploads raw binary data **directly to object storage (S3)**, bypassing application backend servers entirely.  
> 2. **Parallel Chunking (TUS Protocol / S3 Multipart):**  
   * The client splits a 1 GB file into ![][image13] chunks.  
   * Uploads happen in parallel over multiple connections.  
   * If chunk \#42 fails due to network drop, only chunk \#42 is retried rather than restarting the entire 1 GB upload.

## **4\. Asynchronous Video Transcoding Pipeline**

Raw uploaded video (e.g., .mov or .avi at high bitrate) cannot be streamed directly to users because it consumes too much bandwidth and is unplayable on many mobile devices.

### **Transcoding Pipeline DAG (Directed Acyclic Graph)**

                       \+-----------------------+  
                       | Raw Video Ingestion   |  
                       \+-----------+-----------+  
                                   |  
                                   v  
                       \+-----------------------+  
                       | Video Pre-Processing  |  
                       | (Inspection/Validation|  
                       \+-----------+-----------+  
                                   |  
                         Split into 5-sec Segments  
                                   |  
                 \+-----------------+-----------------+  
                 |                                   |  
                 v                                   v  
     \+-----------------------+           \+-----------------------+  
     | Segment 1..N Worker   |           | Audio Extraction      |  
     | Pool (FFmpeg)         |           | (AAC / MP3 Streams)   |  
     \+-----------+-----------+           \+-----------+-----------+  
                 |                                   |  
        Encode to Resolutions                        |  
    (1080p, 720p, 480p, 360p)                        |  
                 |                                   |  
                 \+-----------------+-----------------+  
                                   |  
                                   v  
                       \+-----------------------+  
                       | Playlist Generator    |  
                       | (.m3u8 Manifest Files)|  
                       \+-----------+-----------+  
                                   |  
                                   v  
                       \+-----------------------+  
                       | S3 Production Storage |  
                       \+-----------------------+

### **Transcoding Steps**

> 1. **Pre-Processing:** Extract video properties (codec, aspect ratio, frame rate, audio channels). Check for copyright violations and malware.  
> 2. **Video Splitting (GOP \- Group of Pictures Alignment):**  
   * Cut video into short duration chunks (e.g., ![][image14]) aligned on keyframes (i-frames).  
   * Splitting allows ![][image15] workers to encode individual 5-second chunks in parallel, turning a 2-hour video encoding process from hours into minutes.  
> 3. **Multi-Format & Multi-Bitrate Encoding:**  
   * Video Codecs: **H.264** (universal compatibility), **HEVC / H.265** (higher compression, 4K), **AV1** (next-gen open-source, ultra-efficient compression).  
   * Resolutions: ![][image16], ![][image17], ![][image18], ![][image19].  
> 4. **Manifest Generation:** Build the playlist index files (.m3u8 or .mpd) mapping resolutions to segment URLs.

## **5\. Adaptive Bitrate Streaming (ABS): HLS vs. DASH**

Streaming platforms do not serve single .mp4 files. Instead, they use **Adaptive Bitrate Streaming**.  
Master Playlist (.m3u8)  
├── 1080p Playlist (4,000 kbps) ──\> seg\_1080p\_001.ts, seg\_1080p\_002.ts ...  
├── 720p Playlist  (2,000 kbps) ──\> seg\_720p\_001.ts,  seg\_720p\_002.ts ...  
└── 480p Playlist  (800 kbps)   ──\> seg\_480p\_001.ts,  seg\_480p\_002.ts ...

### **Protocol Comparison**

| Feature | HLS (HTTP Live Streaming) | DASH (Dynamic Adaptive Streaming over HTTP) |
| :---- | :---- | :---- |
| **Created By** | Apple | MPEG International Standard |
| **Container Format** | .ts (MPEG-2 Transport Stream) or .mp4 (fMP4) | .mp4 (Fragmented MP4) |
| **Manifest File** | .m3u8 (M3U Playlist) | .mpd (Media Presentation Description XML) |
| **Device Support** | Native on iOS/Safari, Supported widely on Web/Android. | Standard on Android, Smart TVs, Web (via MSE API). |
| **Verdict** | **Industry Standard for universal streaming.** | Popular for non-Apple ecosystems and DRM integrations. |

### **How Client Quality Switching Works**

> 1. Client video player downloads the **Master Manifest (master.m3u8)**.  
> 2. Player measures real-time network throughput and buffer fill levels:  
   * **High Bandwidth (![][image20]):** Client requests seg\_1080p\_005.ts.  
   * **Network Drop (![][image21]):** Client seamlessly requests the next 5-second chunk at lower resolution seg\_480p\_006.ts.  
> 3. The video continues playing without pausing or triggering a spinner UI.

## **6\. Content Delivery Network (CDN) & Edge Caching Architecture**

Video accounts for over ![][image22] of global internet traffic. Serving all requests directly from origin servers (S3) is cost-prohibitive and introduces massive latency.  
                    \+-----------------------------+  
                    | Origin S3 Bucket (Primary)  |  
                    \+--------------+--------------+  
                                   |  
                         \+---------v---------+  
                         |  Origin Shield    | (Mid-Tier Cache Aggregator)  
                         \+----+---------+----+  
                              |         |  
                  \+-----------+         \+-----------+  
                  |                                 |  
                  v                                 v  
        \+-------------------+             \+-------------------+  
        | Regional CDN PoP  |             | Regional CDN PoP  |  
        | (US-East Edge)    |             | (EU-Central Edge) |  
        \+---------+---------+             \+---------+---------+  
                  |                                 |  
                  v                                 v  
            \[US Viewer\]                       \[EU Viewer\]

### **Tiered Cache Strategy**

> 1. **Edge PoPs (Points of Presence):** Located directly inside Internet Service Provider (ISP) data centers globally. Holds hot video segments in SSD caches.  
> 2. **Origin Shield:** A intermediate caching layer between global CDN edges and origin S3 storage. Consolidates cache misses to prevent "thundering herd" traffic spikes on origin S3 buckets when popular videos drop.  
> 3. **Caching Policies:**  
   * **Manifest Files (.m3u8):** Low TTL (![][image23] for live streams; ![][image24] for static VOD) to allow rapid update propogation.  
   * **Video Chunks (.ts / .m4s):** Immutable. Cached with Cache-Control: max-age=31536000, immutable (cached for up to 1 year).

## **7\. Data Models & Database Design**

### **Relational Database (PostgreSQL / MySQL)**

Used for structured, high-consistency metadata (User profiles, video details, authorization).  
CREATE TABLE videos (  
    video\_id UUID PRIMARY KEY DEFAULT gen\_random\_uuid(),  
    user\_id UUID NOT NULL,  
    title VARCHAR(255) NOT NULL,  
    description TEXT,  
    duration\_seconds INT NOT NULL,  
    status VARCHAR(20) NOT NULL, \-- PENDING, PROCESSING, READY, FAILED  
    master\_manifest\_url VARCHAR(512),  
    thumbnail\_url VARCHAR(512),  
    created\_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT\_TIMESTAMP  
);

CREATE TABLE video\_resolutions (  
    resolution\_id UUID PRIMARY KEY DEFAULT gen\_random\_uuid(),  
    video\_id UUID REFERENCES videos(video\_id),  
    resolution VARCHAR(10) NOT NULL, \-- 1080p, 720p, 480p  
    bitrate\_kbps INT NOT NULL,  
    playlist\_url VARCHAR(512) NOT NULL  
);

### **NoSQL Store (Cassandra / ClickHouse)**

Used for high-throughput write streams (watch progression, view count tracking, streaming analytics).  
CREATE TABLE user\_playback\_history (  
    user\_id uuid,  
    video\_id uuid,  
    last\_playback\_position\_seconds int,  
    completed boolean,  
    updated\_at timestamp,  
    PRIMARY KEY (user\_id, video\_id)  
);

## **8\. Summary Checklist for Interviews**

> 1. **Explain Resumable Uploads:** Highlight pre-signed URLs directly to S3 and chunked parallel uploading (TUS protocol / S3 Multipart) to prevent backend thread exhaustion.  
> 2. **Detail Transcoding Architecture:** Explain why videos are split into short 2-6 second chunks for parallel worker encoding across multiple codecs (H.264, HEVC, AV1) and resolutions.  
> 3. **Demonstrate Adaptive Bitrate Streaming (ABS):** Clearly articulate how HLS/DASH manifest files (.m3u8/.mpd) enable clients to switch quality dynamically based on network bandwidth.  
> 4. **Cover CDN Tiering:** Explain Edge PoP caching, immutable chunk TTL policies, and Origin Shielding to protect primary S3 storage from thundering herd spikes.  
> 5. **Differentiate Storage Tiers:** Hot storage (CDN SSDs), Warm storage (S3 Standard), Cold storage (S3 Glacier for old/unpopular long-tail content).

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGkAAAAZCAYAAAAyoAD7AAAEoklEQVR4Xu2YeaitUxjGH/M8ZSrCIZQMRQghGW9EyVDKEJmSecoQXf7QNSTXLOJK/jEksxSOKfMUhUwhU+Z/pIzPr3etu9+9zrDPOfd07+30/erp7DV8+6xvvcN615Y6Ojo6OjqmzJLWmtbK7cDixqrWXdbP1nfWfdbGfTNmJnOtf6z/rOObscWKJaxh6ySFV+1ifW/9YK3XmzZjmaVFaKRlrSOs5dqBhv2s55q+YxULv6Ppn4lspkVgpBWs06w3rDMUkTIel1l/W2elvvUVCyf1zXQ21UI00orW2dY7ig3HWBOBuSzyntS3Sun7PfUt7pCqp8JCMRLGOVdhnDM1ceNUalpcO/VxLrHwl1NfCxF6ifWY9aT1jPW2tUaac7Qiooet161D0xiQiq+0PrJeKzqhb4a0pyIdv2q9Z12t3jvubH2mcKb7rQPLX77nfWvHMq/Cms9T/L9nFXOP00gjbWU9ZD2sWPuD1jVpfMJU47AxpLfl+4cXiNsVCz+8HUhgAF60soH1q7VWaROh31pDpb2r9a+1V2nj+cMK41XDvqWotup3HKKoOLcsbRyKDcNoSyv2YDvrJ+sr63r10jtGfbN8rtygKIi2KO1lFBmkNdLn1u6pjYFuTO2B4EU1cjDOoMJgsrAhf1l3twMNtyiiJEfundbq1jrWn9acNAbMf6B8PlmxOfv0hnWhda/CAKTcX6zr0jhsrnju1NRH1Pyh/rWwPgxe2Vbx3AWpD7Yv/dVI65b2YfNnSFtbl6f2QAhxPPR8TW/0AJ7JCxPmeNl48FK8DNHDfFItz8ORZQyPxKOrPlGkR3i6zMEYo0EUM35iO6DY/JdS+11FFGaIGp6vZ9Xs0t6/Tii0RlrK+rL0EQhE0E5lbFKwGeRWFne6ps9YePGjirQyCNLKpYpUwwshzgzWVouR9nzJYDDmjFV91u/gOtBClLKRFQyEE2TmKp5n0+G20s5pDFojAdnkBUV6Zozq95g0PilWUs9YlNuTLRoyRALendPnrelzC2fLaopN5qDlQOelTrEOVrzcxfNnj+RFxRxS42iQbhjPaQ1wIP5PNgpnzyAjzS7tfeuEQmsknIy7I5C6D7I+Vlzwx3KoCcEXn6OpV3h7WM+rl66A6HwltVvmaWTZSiFBzudnJiouvDHD72P85AQ1UkiNmaOsHRTFxG/WTf3D2kbxHOdyBScdy0icb1DPJPYnQwVIf436Ietr9RuE6OPMWyAjVTAOiyD82YSJGGtD60frC+uDIkpUPKdu6GjMU8zF2wCjksJq/maz8XjSMS/H2UBkHlDGmU8EkLa4q8BGioqvRjOpDkOxwUD/I4oSO6fkDxUOmsG4bH7+4fRmxVycCDh3KbWZx1WA/Roq7Zyq+fxEak8LbABpB08eZKg5ikWNpivSvBZe+CLrKetxxeZy58jMUhzwGIKoxHAZNouyGc/FsShANumbEQc970G0sMFXKdI87KYooup6v7H2VhQsnCP0UcLjKIBRuNvxfTgM5xTHRH3+U8VVgoxwreL+h3G4T/ErTMcUIJXVKpRo5TN9OGlNTZxJ4xVCjE33Naajo6Ojo6Ojo2NG8D/itRSeVtxMOwAAAABJRU5ErkJggg==>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAAAZCAYAAACB6CjhAAADqElEQVR4Xu2XWaiOURSGX/M8Z8p0KCQJF8gFDuUCUYgkUcpQCBdIyRglUS4MITORDMmchMyijGWeImOUIReK97X2/s/+t/Od853jiv6n3vrX+tZe3/72sPb+gRw5cvyDDKWOUzuoZtEzTwVqC1UxfpBEB1jSO9QDakr249+Uo+ZQN6j71DGqRVZEMnWpTbD8j6nVVJWsiHT586k3VG33+xOsr/UKQtCZOk0tCXxF0o36Ro1ydiPqBTUuEwGUofZS16hazqfOarCq+qAE9PGKW0eVhc3OUdgMetLmP0itDWxN2iRqD3UENmj7Ye0qB3FFcpt6FfkWU+9gnRXDqJ/UhEyEzeAPanrgK4xVsLZtA19f59NsibT5n1KLAnsFbAJDDlF9Il8izWEv1siHaPbl94k2OntgJsJ4SZ2NfDFa8mpbI/C1dr6Fzk6bX7ZvI+IBGAHLlZpOsBdfjvxjnH+Gsw84u18mwnhCfY18Mdqnahvu+RbOd9jZafOfgNUPj5a93/91qJuwLZeaJrAXX4/805x/pbPXO3tQJsLwH6eXJ6H9qJiagc8PvAqeSJu/P/Xc2fnUbucXG6iRgZ0aLf+4Bqio6MVKKrQ0ZY/PRADtnU9qGvhjlsNi2gQ+FS75Hjq7JPm1zM/AimYD5+sFWw2logvsFPCj15O6B3uxCphHg3IVVqVVHFXF37u4+kFcjOK1CtbAToGGsGNK7XQsekqbvxJsEvOcrcHaSZ2kBjhfsXSFHU0qOCosE2Ev1lHk0aViAayT2rs9qGfUd9gZXhSNqc3UJWoXrK3yq5Oe0uZXUfQnheJuUcNhx+AF2ICXmFmwDhY3glo56nBJUeVW/mXxg4ji8rejzqNggLSVNGBaaWIwCgp5IrpaalbCC8dWWAHylVujqRiNrKcV7CNmB77CUCd1gdGe9oyFte3u7NLk1+XpFKygerRi3wa2jltfxxLRzUkv0jYQ2oMfqXmZCKAjLCYsNHOpD8g+dsrDipRuk56psLYzA586fjqw0+YP0V1laeTTdggHQIW32AGYT92FzYLu2LpJnUPBLVBUpz7D7gdCW+ML/jy2JsM+RBXakw9rqxWgpap9/ppqGcSkze9R9b+CP/9PaAWFNWMIUmyBatQ22Pn6CHZsFXa/V6d0bX4CKy75WU+NPrCtE8620DJWO0mDk5f11EiT37Od6h07YZOoo3W0+30R2avxv0AFVH+sksij9sFOtKQV9E+j41Jnf44cOXLk+Bt+ARRU8YKCxBT9AAAAAElFTkSuQmCC>

[image3]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGIAAAAZCAYAAADKQPsMAAAEtElEQVR4Xu2YZ8hcRRSGX42KvUawYUMEe1SsoK5BwRb0jw0Rf6lRMaKREEExiB3F3lAIimBLELv+yooFS9SIGE3UBI0dK6jY9Tycmd1zZ3c/935fPhLhvvCyO+89d+7MnJkzZ0Zq0KBBgwYN6mGbUkiYYJxlfMv4kvFp447RIGGScZ7xReObxunGVSoWyx8PGj8zbpXK+xkvMd5kPC5pWxpnGq8zzkgaWM+4yPhC0FYY1jYeaHzc+GTxLON64wLjuqk81fiFcdOOhbS18Tvjqam8sXGh8eKOxfhgifEfuQPAZOPDSZuVtO3lffjT2E4a2Nb4l/En+WRbYTjL+LXxKXkj+zmCmfa78eSgMctxxBVBu934figDHPazcYNCX55gZR5RaMz06IiMN1R1BDhYvpJXGvyq/o44R96p3Qq9LZ/xAMd8ZZzbeepoyd89odDHG+uovyNeV68jVjoMcsQ98k6V+8djxr+Na8lXDTazKxbSnkm/qtD7YdVSGAKrGzc37m5cP+hrqr8jXlHVEYRlQureQauL0bR7RAxyBGGLTtHhiEeSTvzdJ/2/q2Ih7ZL0+wo9Y5rxE+MvxnPlG+kc42L5gG0mDzvEfAbxVVVXJvVSP2wFfVhHfKzu+xGscML2fOPL8pB2enh+gPEj44/ycZiSfmnfO8Z9u6b1McgR8+QNZVAiHkr6HsZD0v87KxbSTkl/tNAzNjEeL7dZajwx6Wz0OIeBu0E+MPA1edYWcaZG7wjwgHodcaPcCXlv20KeXV2eyqykvYzfyCfSzepmh3yDd0eNQY5o678d0Ur/6zoC4Axs2oX+nnyjZ1AzWHF/hDI4RmNzBCltdMRBqZxT34wz5KGYMJjB7GfCEJ4z7pBnYqMGjiAMlRgUmnKKuIMGh6adk35/oUdsKLchvYygk2yuEWRm2Ma4fFTSWkGr44hrVXVE/kZ5TiK7Qs+rApDSE7YiblFvG2sBRzxTivLBpeLtCp3NGp3ZgJP4f2/FortZX13oETnVLG3elh8MI26V28acnz1kLI7gu9ERuV9lf/dPeuwjTqDOCA6SZRtrAUc8W4ryswAVl5kFsTqeG740PhHK4HD5uycVegSHxGEdcZt6O3lk0lpBq+OIa1R1RP7GrkEDuS+xnewF4+KI50pRvlFx2DslaKSNbFRXBo0l/UEogwvkMZTwMwg5NNVxxGpB6+eIOueI0hGTU5kkIoIMD50wnEFoGuSI2MahwUu/GZ8vHyQQv7lnygM6U36y3qhj4WeJH4ynpTLXH8uMF3Us+oMkgIaTHUW8q974e7fclqwl49ikHRY0sh20OFEAfSAdjeC75cDNlttOTGX6RrpatpGEAruIPFnyddBQOFr+ge/lL0NCzIeqDjLL7DJ1N1CyqzKGAlK6tjzNpIGcDUbChfL7Kb7LqlsqH1AcmNvzqfFQec5PNoL2rfFseebGikOjD5caz0/P0ciwCJ/cpVFPrpP6aSvf47ton6t7VcJGe5784pKVyS8hOoPMCvtcH5eOtJt7r1wfbWAV/S+whrqxlDyc2M7MJPRljf9oPMu5Ou/wLlrOTvhFG6bObBPrxGbYcFLWN1IbGzRo0KBBgwYNGowZ/wKQWVHPlGoBYAAAAABJRU5ErkJggg==>

[image4]: <data:image/png;base64,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>

[image5]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABsAAAAZCAYAAADAHFVeAAABpklEQVR4Xu2UPShGURjHH18lX6V8lrKQQRaLmJkMNhlfYSCDxSKrjAxWFrFIybcwSDKglDKxGWSxUsL/33Ou97zHufe+t5Tl/uo3nOd5e//3nPvcI5LyD1TDZXgCR52eTR8cd4thNLsFwymchUWigYewCxaYfjmcgk+w3tS8lMEeuA13nR7phF+wway74Q6cF/39EdyCD3DE/MYLt/wC9+CH+MMyomHcFamC+z9dhbvk7oOdxvIm/rAx0bBCs2bYQbYtJfAKtlm1WMLCeMQMqzNrHuNiti0zou8zEWFhPJpLOC16lHxHHabXCq9Fd5eIsDBSA9fgORy26seiO01MVJiPDFyy1vz+OCQrop9CJAzjVOZDLbyFlWY9CG9gKRyCC6YeCsPsKYtiFQ5YawZxUAJ43MH0emEYb4Y4euGGteafvsMJq8b322Stf8EwTloUPCZ+U41WjRP6Kblh6xIRViz6dGduw2FO/BfxveR+axfiOcZ++AhfRT9c+ix6z/Gmt2kX3bnvSuID3IlOYV4DEscmbHGLFpOig8HhqXB6iQnGPCXlb/kGIYdQJ1P32tcAAAAASUVORK5CYII=>

[image6]: <data:image/png;base64,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>

[image7]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEUAAAAZCAYAAABnweOlAAAD50lEQVR4Xu2XW6hVVRSGf2+oJd5KTBE9mgYaUakJYuYh0VcvQXiLAi2i8iUDS0QWhZlC+iYGwlHpRaXEe1HkgbKHxAw10aLQPJCmRngNzcv/M+bcZ66xz977tDkPPqwPflhzjLnWmmvMOcccCygoKCjoeB6l3qFGUz2oodRiakvaiXShMuoIdZDaRz2Wdgg8RR2gvqN+pJZQnXI98rxFXabuBp3Mu8tYjda+16n9wd5C3Uh8l6i/qPPU39QhakHoW5OpaH1Q+rJpaSfyMfUT1Su0X6f+pAaUelhANYCXQrs/dYJaXupRGX3sH7D3j3e+SGdYENTn99BO0djk+83ZH6A2wXyr8q62aaQuUqepX6gmalTiF0Oom9TcxKbZV1BWJrb1KJ9pBe8a1cfZPRlswBr4uryrxPPUUlReUV1hvp+9AxYwraTbsO+pymRYFKvxJuxlTzh7M2wlCAVJS/WzktdohN37orN7MmombJYVbG1Xz0aqAbWDctw7Amdgfn1zVZ5F7aBoMHrYMGffSd2hesKirz5aaSlPB3utZZvBgqKVp/7Tc16gOyyPiXqCMoi6BcszvZ2vjEnULuoT6mvY0lNyTNkLe5kenLI92EdQz4RrPSfl8WD3iduTwYIS+2/OeYEXYAeA+L9BUd7Tt12gnnO+NplInYOdPkIfrmhmsQPsNNHLHklsYmuwP0lNCdcbcj3subLvcHZPBguKOEpdgSXIyDZqYLiuFRTlsOZE2jan0I5tE3kQNtMpmqV/0RqEZtQOSmO47oigvAe7Jyb2vtSecC1qBcWvFPEqLMmu9Y728gHs4fNCu9L20ezJPhKVt8+YYP/U2T0ZWoPSALsnBmIRtTBci3qCIj6H+V9x9jK+pQ4jn+1XwG5WUSf0oWoPL/UwlGhlV6JVwHTtc0FMtB85uyejZiXt72GJ8WHqS6pf4qs3KG/A/N94R4oC8R+sotSHRdbAbp4f2qo11B5X6mGosk0Hp9y0O2kLFYG6d46zezJqdtJWUtV9OrX81qs3KK/B/Bp3VVSKT3C2L6ir1EOhPRgWvBgk0Q1W9H2Y2FS8/Zq0xduwCll5oRoZ7ISJKKnqncoDPqD1BkU1lPzLvMMzA7Z346A1MA1E+zhFZb7+e2K/d2FFVrqsVav8Q70c2joKz8ISZzV0yqh81xZLS/evYJOjwyCiFa0PU5nv/6lUNbcVME1grIT1q5KeahXRTOgY1Afow9MZi2irvU8dg/1cKZA+x4ixsNPqB9izYm1RCVXLmgQNWNKqUu0k9A/VFK6Fql35Y19t+5iMW5xPR7pWsmoTHdHy6+SJ/24FBQUFBQUF9y/3AAsqFotrrl8xAAAAAElFTkSuQmCC>

[image8]: <data:image/png;base64,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>

[image9]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAWgAAAAZCAYAAAAc7LQFAAANKElEQVR4Xu2cB5ReRRXH/ypi79hbEFCsWFCwZhEFe1ewJnrCUY/osSIqagQVEbFhLyQiiAU9ASu2LBo7igULqCRIQBFUREWxz+/c7+7O3n1l3pfdbLKZ3zn3nGTefN/33rw7/3vnziRSpVKpVCqVSqVSqVQqlUqlss1y+2SvjY0FXDHZjZJtFy9UKiOukOwTsbEyt1wn2QeS/TDZj5N9IdluM3osDpbEhg52SvbiZLdNduVkt0j23GTH5p0Ceya7ONl/kv0v2X+T/Wlkf0+2Idk7ku0w6g/PS/ZHWV8+Q78Lk/0+2e9Gdkyym/oHxuD1yfaNjT2cLrsfbOdwbWvmQcmWJ7u57L3yft+c7IVZn8g1kp0v65uzIdltQlsph8n8he++XrJHJ/vOjB6zuSjZZZp+L5fIfOuvyf6Q7FPJ7jDVW7qb7DP/kvXHL3Pf4jOfk93HuOyT7PDYWJlbTk22YvRnIuLXk/0t2a2nemy9kAXuKpuEiGcpe2t6IrhdmuyBeacWniDr/7Gs7XLJ7prszGQbk90suwZvkn3mqaH9XrL7ZkIRJMbhuxqeBV9eNvEWm0AjjPG9ni0T7DaOlPXLxe8qo7Y2y999hDkW+2OH5J1auIGs729lPuUQwE9K9k+ZaOY8TPaZD4b2m8gCMZ+hzziQPNwlNlbmjiWyl7chazto1Iaobc3cUZYlfCvZb2SZRikTsuxjQ7Kzkq1Ktkt2vQufEKtDOzxedo1sJ4cSBO1cj/i198ULBeyh8T4HB8h+dzEJ9Mpk58iC5I+SvS7ZtfIOAd45qxrGIRdosmnayGARy/Nk30mmTcZ6j+mujfxDFqy5l0+rLPDD1TV7vjrXl127QDMD8gNG7e/M2hy/ho8PZXv1Z/2VTYTl1Z+TnZG1HSx7aW/M2rZ2KNsMEej7qllgS+gSaLINrrFUJbt3XIQfl7U5T5dd+0q8UMBbkt0/NhbCqmqxCfQrZSWOUtbIylpRoB+a7Kjs7w5zpyQT/nVsKKRLoIG5zPWlWZuLMOW1yI6yawQVVk1DeGSyQ2NjxbiaLGL2kYtAG2QQ1OOcE2UvDZHKoVa9V2jLYcn1qNg4RzwjNgxkqEDfR80CW0KXQJPRco1lZalAk/lwjck/BCbcD2RL6nEYR6B5Jv89/MH9inb+nrf1cV1ZjbaPEh93EM/lsbEF6vbvlu1FRIHGz2PWSwnryyob71/FhkL6BNqz/YmsrUugfUXH/BjKCbIN6Dbwv/zd8N55/4yPj9GVRm2LBl7Qh5P9W7ZMYmmyTM0PyQCxQTQEMgOiaVP2zGCeIuvTxNtlzjwffF5WfxuXoQJ972QnJ3uvbNL9NNmLZvRop0ugPRv+ZGhvE+j9ZGJ+vIYJEUyoeVI2QZB+j0w4WHKv0vQ95QJ9z2RfSvYZ2d4FWT1tDhOejSg+h+EvwCact31v1NbGLrKyFJtaPDu/Qy2+idtpdt2+i1fI6v2MP3st1OcfMqOHQYngG7IN3SaBjjA3vq3uWnbOelnA/aJs9UoguOaMHs10CbRnw+xX5L7SJtB3SnauLIgP3YS+qvrLG+yZ8P3+3vELAu7dNb2R/hfZSSG4cbKPJPt+snWy+ZMnoX2+d0PZIQdKTt+UBWPG1t/jZoFBfnWya8tEGcflhrkJdm1zOCHAyYMSlspqcogYAaBNDBhgHPvBof0IWT1vvmCX+w2xcQBDBZoXj6P7zj3Ow+73Su/QQZtA835Y2jI52aDJcTEkEEyOjAnAZi2CwoppKAguK4E+EBdE82syvwKCIf7APeUCvXbUhogCAYesDaF0yI54jnOyNkCMnh/aIvg0k4vARI2TeyNo/UQWNPJxQ0TZjENoSnmZ7Dm97ox4kZDEbJi584LRn0sE+lWyOVAKG84ejJlrXx1ZU6KV0ybQjAsnMvheninHBfo8TfsWY8DpIRKfcTaf91dZKQfwQ36fAOK8XHY8z3WG1RKbtYeP/o4PcW/cp9Pne/gDGT2n0ZjrfJeXa+drZT8LMromyAJ+IXPuD8miIg+Igw+B3WkiE5EIUWqCwUQ8JkZ/xzmPnro6fzAZx62nDhVoBPFWoY1xZdXiEb8NF2g2kHAW7GcykcFpXARz2jJosoLTZBOSTc9ScFZ8oG/CA0LEb+8Z2l2YcoFmGf9ETX8vE4kjgj6xnJfKPktJB1jN8Rx9y39O3Lgw5vA8iDvZEQkJmdb6ZK/JOxVApkipLodAwjty8G8yeBePPoHm+6j93jle6CC+S8SmREhcoAkq7lsE0l/KApgnFDltGTQlB47XMi94p0NYo/LSl5f18AmH95eXR9groSqQJyKs1PNxL/W942Sf46QUc+0pak845xyPHk0wCVia87LjZBsCIsgDEpHbIMNiwvHSOb5TIgSbCssqHONADR9wBJpsdFM4TDYuT4oXAi7QJ8YLHbQJNJAhco3su0/gHM77knmXMCn7fsY3p0mgASFiQq2VZTj0edeMHiaELGM9cO+lslNBrNAISm0gUKzenqbZ9zUurAh5Bs/O8em8jNcn0AQORI75Ny57y36j78SNC/RF8UIHbQINJHAEvctUfqyW1Qcr9iGQPJKgACLMmOdQWqOcRZnIjVLHRs1Mykp8D4EmYC4YnLM9VRY9udm2TBdWxIYAg8VuLJmzs0T24ESnrroYokINiZrSUIig68awM2X3hVgOAYFmOVQKDoSD5ILISoFxYcJ2MdcCDZRXuH6/eKEFsv3S9+JjGmkSaMSITGelLNMEhJgaaoSSBve9nSxTiyW4NuhPrZjxZ0VI7b9tJYiYM94lEDQQI/ZKcigt8Jy7y7I6MvScPoFGTCjplEIpkHHJx5X3ym/E347MtUDDx2XX8e8SSABfEht7oKTBb+wmy2jjfg6CSgmmi1LfO072nhcENkRwCESal8omIEs0Bi2CszHxu/D6UO60ZOm0YRzDa+LZshoS9SvuJ69BzhfcFyJdOtFzEGjKEyUgyjjCJZoZuNg4ZUyenLU1MR8Cfb7seqyVNoGYIW6lTMq+O4pgFOidZONywlQPA3FnkrBBlm/kMhH9mfCRUliRHS/LlPeV7YkggE0bhc/R7JprGxOy+2GjKYeNQtoRcDYzOTvP/oMb2bGLIqW/HDJ+RGIytHcxKfs+VrsOJUra3p+1NTEfAk2yxHUCRwnj1K3pj58cKZuLcQ+GMg3zs22FOMT3EOiNUz02M0S7XDSAWstnZS+epRlCtp9sSRHrqBEX6Lw+xPKYNgatiWWySO9lhlvKanYM4nyBeLCsWhLaS8EpWMY1QRBCdPOyCfXb+I8NvI7dFrQcF+h4UqOLLoH2EgdZRnz3TbAi6gvMOWQmfH+soR40aveyGt/L3w+c6mH1V9rwI2rHj8muISaUlRA5MuISGNvVsVEmzoj0MbLyHckHv8deSNukjjCBz9bMPYDtZYEY/20DYeMZmzJofIRriFYTrAb218x9i7dq9irsYNn3EJC6cIEmiJTSJdA8vwf/pgAY2UHDglEOq/4L1Xykb6XsHuIeE35DIBviewsq0F2nMsiqyVQYBOoz+RGUNpiUF8hqYNSR2Tggw6Ac0HQC4LGy2jT9cpjEODnBYj7guZ8VGwfAxicbK021azJdXnQ+tjgEQcgnM89NprRiqkc7HDXj+2Km1gWlKj7DZM7ZVRZoyRT6MneHLCNuQnVB8CMg4di+l0DpgLog9/Rw2biR9eAXHx31AQLBxbLVFH+OJRgyYe59x9DeBnXQfWLjCO6TUxg/ly1h2TQm6x0CdfBDZaKOeB4lK9PF4JTjSUzTaZFHyK6dFC+MQFC4ngdrssnTNf3/eLCxRxBjpdAHx874PgIf4lqCixvPkUOZgDHkWl/t23mmujWoiwNkv7U8tAOlVhJCfN01hIBI4MMnh/jeyTINLA3cWzxkJKfI/jn0epmzNTkstW5Eqy2LI6uJS5C5YlLtv9sG0R6R8QwB44XSxirBoT7GiYulWRsglixpz5VNKES6iz008z+nwci4j847BTjOxXEnRIz+fJa/42BkSTjlpMqX8SXnU5sgu1wtqxtT7sK4b38OashAID9Ndjac5Ti76owL2f1qzd4sZjWxLrQtJExaJvNZMr8gm2sSXuDZmA8srRkDfCRm2gQU3hWrkCbICPE5ViM5nEggieL72fwlU+wTFEQcf/B3wooQv2yDUmDuj/gY90Ib98x3nSELIvG9tUHSka8GhkCyw2qFslAT7He9TVayRawJHiQKTp/vUebgzz4+l6r7/0SpzCG7x4ZKI2Tvh8TGMUHs+0SjD7KtklVHZcsHsSSRGxdWdazSKpVtFpZ7O8fGzQjLdjJmP0FCltiWMVW2Lsi0hwRbSjDsjVHaAGrvE1NXK5VtDOp4bMQsJGxysrxcJjtxVHoyoLLlQ3mDjblSKDHiC6tkeymUzyqVbRY2iTkmtpCwT8AymCz6WJVvZFW2bKg7r4mNBRwh2xNZq/L/p6RSWZRwEmToqYZKpQSO7fZtklcqlUqlUqlUKpVKIf8H/GRiHVIdj7IAAAAASUVORK5CYII=>

[image10]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFcAAAAZCAYAAABEmrJwAAADtklEQVR4Xu2YWahNURjH/7jmmcjslDHzi5LonngxPKCUPOAolLwgY0qhKMWDIYqHm3mWMlyZNvKgyJhCuK48yJAxmX3/vrXOXnvfs889V9elc/av/rnr+76znfXfa6/17QPExMTEFAS1Ra1FTcKJfKGlaLvopui2qFQ0MFBRkX2iT6JfRluC6QpchV/7XrRMtEn0w8Rm+KX5xUX4k6sjugw1rme6IhqaVi56LaoXyll6i25BTSwJpjDGxPPS3AR0cmVObJGJrXdiUXiiNdD6ccFUmpWixdCaraEcjc9bc7nfvRPddWJLoBNe68Si8KBbyE/RwWAqzRlREpnN5dORt+aS5qIGzvgQdMLDnVgUnqiF6IroM/RaLkNEq1HA5rqMFX1DbquWeFBz50BNmh7IAhtF/RFtbg8TX2Fy+0WPRDtEbUxNO9E90QvRU9EU0SnoAfxQNM3UWSaIToiOiy6JTovGByoiOAq9aK5aoB+rlGLoofNRtFNUN5iOxIOa21b0XXTOyRWJzpu/k8hu7h2oiaQxdCuhoY2g1+kLnQ9rV0EPXrLcxGaacTfRK1FTM64PfaommvE/pSHUILZk7UO5THhQcwlXCFurjmY8GtpykSQym9vdxOeG4oNN3F0cB0RvnTFhn1wmegm9KZOgCyThl2AW9Lv8F4yATuxkOJEBD765KQQN2QVdSSRpcrmay5vM+FkntgcVzSW8JmuHQbsPPkFfoN+Nq7xLurKG4d1mC8XJWBLQL8sOoJkTz4QHfQkhrOWhdgN6XbslkCSqZi7h/3/fGfNmZTKXrR6vMdmMuec+MDGKPfgAk8sKT/JrVdB8/Vgk9q5vcGJ2H6TYqmXDE7Vyxoehn2OHMM+JJ008V3PtyuVWY4kyl2+HduX2EvUx8c6i2dBWk1tKjWPNZZNvGWViPOAqw0PwBvDg4GfZcXRw4kkTjzI3vAiGmrjbotFcvjq78GB7LHoGPYRT0DoXHnqloViNMAja4owU1YL2uzyp+XhzJWSDK4OT4iushZ+nARecGOGBQrNKQnFrLreShIlxS2EL5UEPLAtNY+1CJ8aWkTeSLSRJQV/d3d9GdkPfOv8JbPT5+JWLnoiOQU3PBn+44USt+OhZtkEnSfpBW6Ov8GvfiJaaPM3lE9IV+obHA4wtGB91205Z7LaQEh0RXYf+DlLs1LAH3gztl9nrsvNZh9xby4Ilas+NqQb2Ijb3r8Ht6gP8t7OYaqCT6DmCe/bUQEXMH8MuhgcS/yVcuUV+OiamUPkN958Ay+fRLpIAAAAASUVORK5CYII=>

[image11]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAG0AAAAZCAYAAAA7S6CBAAAEOElEQVR4Xu2YW6hVVRSGh91QKwtN0IqoHoS84d0Kyt0hoaSwF8sX6Uk9CimliIK3B8kKI7M7PRyMoKtE9NRTBzTRLDPEO3rUSgy6QkpQVuNrzOkee+69j2ufS+ewmR/87L3+NdZcc82x1lxjLpFMJpPJZDKNMEI1MDUDE1SfqXao9qqWqQZURPQ876q+V90ctqer1qheVD0SvJtUK1WbVCuCB9eqjqi2O69pYOBvVC1V/aiaUrn7P25R/ayaF7aHqg6qVl+M6B1OqP4RSxa0qN4P3vrg3a56XvWXqj14cKvqgup31eXObwpOiiXgK7HBqJW0V1WHE69VdU51XeL3JKNUDyQeT5BPWoT+tyfevWIzRNPCFFMraTyJP6i2JX5JLP7RxO9trpbaSdsj1UlreuoljfcJflviTwz+xsSvxWWpUYArVSNV41VDnM87t1bSdkll0gaLTeuTndcoXen3/0q9pE0N/huJPyb4byV+ZInqtOq86gmxIuFD1VGxwaXoYerjHcWA71aN48AA7dI+Kjm/aNJOSfl4DzPHItWXqp1i0+p8t/8u1XHVb6oPVA+HX/q3XzWtHFqMj1T7GtByO6wQ9ZI2I/ivJ/4dwadPtRimmiMW06F6LPgUMSSSQX5BbBDRF6rPQ0xkoXQ9afCOVCdts1jC4ruYIowqc0PY5gmdJFaUcdNtkXKVzDk4tt9QL2ml4DeaNCBxxLQn/iGxIsYvL3iS/3Tb8JB0L2ksA3zS7gnbcbkQWaD6W2wqjvBUcXMNct5rYhVpvyEmjenQU296HB38txPfc71YDCW5hwGhcPBQoRLr3yOzgldyXiNJe04qkxbPQVXqocrEj08bMFMxdXpekuo+9ikxaXFNFKEYwN+a+LEQeSbxPbE8T2O+EVuke14Wi/VrKt553Uka5/VJ+zhs3+Y8uDP4/hpJGG16WNSnfbwkvMiZU4vqKTusEDFpXEDKWdUniTdTLH5u4nuukeJJe0WqB+TB4JWc10jSnpXKpMVzjHUexGvx/WT8eiRpvUlMGtVTCtPKscTjhmDOZwqsR5weG0naFc6rlbRG1mlp0lrCNgWSh0oX378amB7rJc33sU9ZK9ah+9IdYmu1X1WPh+3hqm9Vqy5G1IaynjapEj0HpPp98aZYLNVbZHbw7nceVR/e086Dr8VKeA/nTQe5TSz2hrDNtVHip32kWCLOE28sZpA+5VOxNQ3f7ujQH2Lf/Nb5ILEyuF2sNOdiWHt1BssNvlfSJm13iA0+ycZD34ndJJyfqgzvJ9Vi1XtiTzLeL2L9eTLsx6PSPKy6W6yd2Cbt01fOF6/pjJQ/h1FELBX76M0Tz29r2AdUmMTH9vhgTb8Zk9gefeDpbDqukvLczzqHdxF3PF86osd/PPbFtRDHcCxerNL4xSvSZozxbRJTdEpL2+usj5lMJpPJZDKZTA/xLwlqOIzHvVQnAAAAAElFTkSuQmCC>

[image12]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAR4AAAAZCAYAAADnu0HaAAAIS0lEQVR4Xu2cB6wcNRBAh957r/n0Kjqikw+IEoggIAQECfhCdASh93JCQjTREQRECRCQ6B1CDSUg0XsI/QOhii56n8fY+T5n93bvXyHc95NG3I73fryzM2N77EMkkUgkEolEIpGol9VURqtcoHJ21JZIJBJNZzGVN1RmV1lL5Q+V6avu6GymU1lQZdq4IdEyks1rgGFmjJUOZghjVcapvKByuMpUVXe0l0b6epHKOe4z+kFBW7tYUeVesf6RBK9Umbvqjsn5WOVXlb+d7FzdXMU8Kj+J3fenyrcqg1VecTpk6Ul3dxZzqVyu8pLY845RWbXqDqPIT7J4WMx236u8o/K+u0Ymqryr8pW77rWvDAib1w2GXlhlhMqXYjOAmMVVvlbZzV0TIONVTph0R3toVl8J9OtVjlIZpbJ90NYO5hdz0NXdNUkUZ6WfRSPizCqfqPyucnfUFrKfystizt4T6KdWOcPpOzUIHlPZy32eRuUJlR9Vlp10Rzk/yYJkdpZUvyd8EXuS7AE/PUDlB3c9EGxeN71iBn9ezDBZwXyxyoRIh2PzMueI9K2kV5rTVxzuRvcZZ6FtAXfdDnrE+n91oGP2g27bQJcHzn+fWPKZN2rz3Klymtjf3CVqwx6dGgRdUj3bAAYYdH6WC2X8JAtmOTNFus/F/v6ckf496ZuVd7LNG+IYyQ5msjeGvSXSd4vdv1OkbweN9vUDlSMmtZqz7Rpct5otVP4SW/J5WA7Qx60DXR4knt3F7j8wagNG8ytUKpKdePZx+k4MAgaS71ReC3TeX85012X9JIunY4XkJ57bVRZxnzvZ5g2RF8yLOv1VkZ5lAnpG1Vqwtl4qVgZQ4N00VhbQaF/vVzm4r/nfWkiteolniEw+2oWsoLJcrMxhPrEpOLAcwHmZiWGPIkg8s6n8rPJU1AbYh+RWkYGXeIAZS1j/u1nseTdy12X9JGYGletipeQnHv7O8u5zp9u83+QF89pOf2mkX8npr4n0MUuIjRJLxg3KrGLFOu8QZWm0rz3St8zBCVmjU5AsYqjYEicr+ZB0SAL1LtmoFZyi8pvKsKgtDxIP3CT2XLFtHxJLZhXJTjx7Oz31DQLpLrFlAf3ge7CNyltiyfBWlZPFZmW9YjWTdd19wAziRLGaE/bhnVKsLWPTVsNzsCT1sx0o6ydlyUs8If9rm98m5nRlJVxOFJEXzIOdfmSkJ9DQ06cieKEYpSvQEbwPiBm7XprRV0ajy5xu/UBfxHAxZ2D08zCje0YsydbDoSpviu1UUYwsi088O4g9Fw7oWUX6lnAVqZ14CAB/jGCQyqdixXZgRrWeWN+YWW3n9Dw3z/+D2K4QsOx7xH2GxVS+kfz6EzDjwydin60l3XyxJPgCxXX6ea3YdnbYVtZPyvCZlE88/6XNp0jygrnb6Rt9SWuKORq7UhieTF1rLV2LVve1CHZM7hCbrfDCSTr8G/2lS8wB2WkLAyQPn3hYTlDPmBC0naGygftckezEQ//Reyf2HOn0zAg8X4jVKkJYLlCjoiAOl6g8K9UzQY4H1ArEdkGfmA2wpb2Q03VLc/2kTOIZSDavCx/MoQEgb1rKORT0oyN9LQgIghSj9lQ31UU7+lrECLHaAcvI2Jn6A1Nu+sgOTBE+8cAose+RhJl+j3P/hYprK5t4hjh9uKXM1n0cBECyY2SmTuX/HiMuCfkQsW3/KQVqiPTPB22z/aSRxNOpNi+ND+Z1Ij2jBPpw6xd8Ie70SF8LZghMDzFgI2vRdvS1CP4tdsd46T7Qy8IsieJvSI9YHzkqUARLCA9/h++dKzaSh7WMimsrm3gGO30YkBMlOwgeF7sXO/D8J0nfeRaEPv4XgTCL2BIlnAl0ifWJGQPF+2b7SSOJ539hc0bY5+qQw+xrpfDBvG7cIGZYimEhm0u2U+dBlmYpQWbuFjsxypq2P7S6r0WwjmamwwzuaLEzIfVA4qU/1Gg8vgbwaqDLg2WDx++IsVRjqk3weCqS/dx5QeBH32MDXV4QcAiT3UCWzZuJ7SQRDCuLHbAjyGvVrajxMPuNfbaWEKRFjBR7Bn6D51nG6RB/yK+ZftJI4mmnzadIfDCvFzeIBdbbkY6khhFqGduDcTjCfnyg21JsWzscmcrSyr4Wwct+UuzFeypitZWykHj4fZivxQCjLM90fqDLI05OFJP57uuRvuL0cSD5IFgj0h8n9vOK8EgAQcBhxBCK6Tj5De56lPSdFPYws+U9tRufeBgQPFs5XThTbKaf1JN4OtHmDcG0DcNsEjeIbTl/q7KHu2a0+kiqs3QtzhOrYcRsL2bgMgXVkFb2tRZMY3m5jFIx/MK96Li9Z3+xQjsjMbD0Yl3/vhTvSnSL/byC73hIYNjj5EAHJEP0PZEeh/1RrIjK0gRwbGZO8XsiCH5R2dBdc/9Ysf4OcrpRYgf2fOBR9Caos2akrYYZBc/BwMCAR18eFNsl8s8AzfITBk62v7Gzt0cWnWzzfsGsg1oFIzDG44Hfk8mdmEz9qNj0+EWVg6pa8xmmcmqsDBgulvXL0Oq+FkH9ZGisDLhQyi0HgPMcJJ9esd9tMQLPH96QgR9ZEUY/PyoSYMx2lnXX+4oFA/dwL+dYvlTZ2LUTBCxF6Cs2xanHi434cb2KIOAe3iFnS5juM+p2BffQd97hGJV7xGy/Z9Debgg++vyhWDKnDhcvcaARP+EoBjbm/JV/J/glxV7OUcV0us0TiaZCEGTVGxKtI9k8MeChaJ2CoL0kmycGNOxEsnTgSH6iPSSbJwY0O0rf/9AKobDpa0iJ1pBsnhjwTCt9P16k+MnOI6NxonUkmycSiUQikUi0nX8AsgbbKcOFddoAAAAASUVORK5CYII=>

[image13]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGkAAAAZCAYAAAAyoAD7AAAFIElEQVR4Xu2YZ8gkRRCGX3OOmONnQFBRzwSiyH2ICQMmTIh4oKKgguGHWVY9IyZExcjhIYKKmPVU9DuMqGBOmMCcA0bM1kN17/bUt7uzu8epP+aBl52u7p3p6erqrh6poaGhoaHh/8fuppdNP6bfw03zVFpI85laphdMT5ruN61XNkhMMU2YnjA9bzpBk+81t9nZNM20umlh0/qmS0zHF20iR5u+N/2d9Ga1ehIXqNP2Z9MDps1NX5l+T/Y/TV+avjB9ZvpaPm5baUi2lw/miqYlTVfKHzC9bGRcbHrRtHgqH2n61LR8u4W0hukb08GpvKzpddNp7Rb/DmerM4BZ78mdVgeD/4H8P1uEusy8cqfk+1Iu2S3V3RDsq8gn+W/yNgPztGlqUSZi3jX9pc5LrSa/8YG5kTw6cNI5he0qTZ6BOPMn01LBPjdpmd43fWR6Sd7HQZ/fMp0nH+RLq1VttjOdqN4Rx8SnjgkfyXVvxYpe4BBCktlQvsR18hsdkcpHpfJG7RbObHmkAE773HR7u9YZl/93v2Cfm5wuX+5GoWXaUz5RmYSMUeR605jqnXRFrDDWktexJMYI7AqNvpX/ad3CztKG7bhUplOU12y3cO6SR9wi8mijzYxKC2nTZGd29mMT0zrRWMBSzAweBJbXadE4IC25k4g++r1jpVZaSL6vwChO2ldeNytW9INB3CHYHpLfKNvvS+WV2y2c25J9bdOW6fqaSgtpw2SfGewRZtgz8ntF2AcfMW0bK3pwqukieVQ/bnrWtEulRW9aciflft9YqZX2MR2Trod10samD+U5wKqhbijY/AnF19QJxwn5Q1fKjRK3JDtRMDVdX11p4ZkV9juCvRsMDC8wVtiIUibNroWtjpNNj6mzhDNovFOcjN1oyZ0EZLo/mBZt10q3ypMsqHPSx/ItAdEfkioSDsZ4jrhZnori9cxs1TtpPF3PiZOANBZHkQktaLpXw+9nzNJlgo1Eguy0jpY6TsLZ9D0nTEvL+5Opc1KMJI4DbB0cdcokbChIncnExoO913LHrMLOftZrudsg2W8K9n5sI1+i7tToe0uEZY9+4Px+tNRx0pj8P9kxh5kOTdcwrJOAPY2E5Fd1P2f2hWjgINZtc2bgeSj7RgmJA3aWJBzIdVzDc+JwfrD3Y37To/IBiBFRB1HEIFwe7NyPfvQ6+2Rapr2K8lPypXI504Oq9mcUJ0Ge3GfEin5w6HxDflLPjJv2T9ecdbgpS1EJXx7KTnKqvqcoA/sA/z0g2HvBPsiSe6y8DxOmJcoGNYzLn/dwsBOZ2Os27JZp76JMksD/yE7jkj2qk3g/6sszZl84B5BSkrWUnGnaI12zRPxhOqhTrQXkkXduYeMw+3ZRBj7F8NmE9bwOzlqs2WRnmZ3kM5hoHYQV5Oe+8nnsbeyzHNzraKk6FiQJvDvnyTjRRnESfflEXr91qOvJhfJ96NUksrp35Gsm+0mGsxOfNPLLnyRfVsrw56z0nemQVOaTESknG/AgXGY6Kxrly8/d8okxCHyn4z5MQJZO+k6WNqVs1AWyOLIvluac2QJRyWa/WGFj0jDQTIj4bZLJTV1MolixcrJ1bajrSX5QN3FIJRvJ8MK8+Cum5+SbadyjYDN5NsjyglPzmaKOfIDsBdnQKdHYA/o6Xf7phVk7S9VstRt8VSFa8vsT/SQwQEI1I10DXyOoz22JUsYjfmBlDJm02PjQ+os8EPiYGx3b0NDQ0NDQ0NDQ0PDf8w9e41Sy12CgiAAAAABJRU5ErkJggg==>

[image14]: <data:image/png;base64,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>

[image15]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAB8AAAAZCAYAAADJ9/UkAAAB5klEQVR4Xu2VO0heQRCFR9QiEvABQpQQUURIRHxhY+PfpEovioitImmSJoKFBHw0aUVBECVNFBEf8VGpkDQKKggiaKoUiSJqo5ggieew63V31ouFYHUPfHD37NyZvfvvzi+SKJFRkTas0kEP2ALfwQIocwOsqsAK+AY2wXuQ5kUoZYF6MAvm1dyNPoFt8NSO28EvkB9FiLwAJ6DVjvPALuiOIpQ6wBH4Cq7k7uLPwV/Q7Hj8GhbvdbxBsOeMKS7yHGQrP9Cl3F28E/wHFcpfFfNlFBdzCKaiWaOUmHcblR8orviImAT6PMyAf+CJmN1hzKgXIVJt/X7lB4orzp+ECQqUP2n9ElBnn4e9CJFy648rP1BccZ5eJnim/C/WrwQN9nnIixB5af1p5QeKK74q9xdP2ecHFecWa8Vt+4T1SyV+219Z/7PyA7H4ojbFJGSCYuXzwNHngePC+DzmRdweuAHlB2LxJW2KuatMUKt8djr3Xv8Gc86Yei3m3SblB2LxZW1ChWIaUIvjZYJj0Od4bDL7zph6By5AjvI9ZYA/YE1PWLG9sq/fJPkgpsPlRhHmrp+BNjtm6/0JuqIIpTfgBzgVsz2E23cgfmL+sXwEO2BDzK3QZ4CqEXM71sUs9q03myhRosfUNTqDdp1CwGKdAAAAAElFTkSuQmCC>

[image16]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADUAAAAZCAYAAACRiGY9AAADI0lEQVR4Xu2WWchNURTHl3meQhmTIckcRXkkHih5MqQ8mT15UJKQkBflwZz0yZAhRN9nKHE9iBAiokikzMlUZv5/a+1z1rc7J1ddX92v+69fnfXf+9y71znrrL1FKqqoorpQr9gwNQKrwA1wEZwE/f0E0xBwFtwRnbtC9F6vTmAvuAquge2gTa0ZJVBLMAacANXRWNAGcBO0tng+eAY6JzNEuoFbYLDFzcFhsCmZoQleATtBA4v3iT6IkmkBeAlqwHfJTqoH+ApmOI8LYlJrncfrZS6muoIvkr6JqeCX6AMIGmDeeOeVTJ8lO6lFon/K0vIqgLsu5hM/4mKKVcB7O1rMN/cmHf4jvq0fYEvkl0R5SbFUuLD4ezsOfoIWFq8RnVcF2po3B5yza+oBeOTioHfgUmyWQnlJsTS5WJaSF586/T4W9wSvzOPCl4ProLuNU5/AfRcH8b4nds0m9FR0PbPAUdGq4GeyHjS2eUUpL6nzogvtEvkHzR/mPJboR/PJNtDEjfPN3nNx0Avw1q57g12i9zPBDuaPA99EO2fRykuqIMUl1QqcAjtE23RI7JiNs7kw/ltS1ELRucOdR+0xf1Tk54pJsdRi5ZXfIfP7WVwlmmjQZPBadM4U8/LKj6XFkguaK9lJTTefpV2UmBSfdKzw1FkWXmwU9NkouKGygw2tNUOkL3gPNlvMhB6nw4nYKC67eLZkJzXWfK6pKDGp07EputHyh0ZGPk8WoZQGis5plw4nOgC2uusPboziN8d7+f0F5SU1zfx/elNnYlN0o+TGPNN5XAhLa53F3I+42InJjFQXRMuGCpuv74gjzJvgvJAUx7x2i1bEoMjPFNskd34uIEs8JvEs197ipaInitCZqCWibXm0xc3AStFGE85/DSU9JvGa/8vmFD/MkBSbTFPz+I0yofAgczUJPBTtPPwR8lx0k/QL5qJWg9uiB1EuJP7GKC6Gc5gcf3ej6Fv04uliv+hZkvBsGM8JSfEYx4ZUEP1dbuZlq7xvqqw1T+phUotFkwrfZ9mLWwWPQ0yKm/V/Ob3XtdjteKSi2CH92bGieqHfrdbPWvG8WGAAAAAASUVORK5CYII=>

[image17]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACoAAAAZCAYAAABHLbxYAAACnklEQVR4Xu2WSehNcRTHj1lkzsKQIVLYoGRIeRtDWdggimSDjTIspJQoQ9nYmJVMC2Qu08YcSSwIsaDMZCpjhO+3c+79n3ve/77X3z911fvUp94599x7f+83XpEaNf4P5sJtsGW8EGgPd8K38AU8APtmKpQh8By8DG/CJbBJpuIvWQd/V3Cg6IvOw3mwKRwNX8JXsLvU0Qu+g7Ms7gzvwuVpRSPYD7/B1/AZfGp+gsesZoJoL3nmiP6RHS63Cd53MZkPP8MOId9grsGOIdcF3oBdLV4Jf8JFaYVID9GGchoQ9jp7+FBaoZRE66aFfIPZGBPgIBzvYjaQL9vjcu0s99HinhZzHnuGWn5tyDeamXBDyHGhzZC6Hiacp2zAFYuHW7w1rVAGW343nAQfiM7jw3AFPA0fw0twpN5SnU6i85OLoBrbJTukYy3eklYoXIzMHxEdhVHwO/wKJ1tNK9EGc11w16jKKng0JuuBvfQD7nK5klRvaAIXbnxPf/gLngz5MlqIPmBpvBBoA2+L7gi8JyFv6AdZfq/LPZfyhhLuGOxtboG5TBR94NR4IbAPnpDyA6Kb6P2+l0mymLhfJ3B61dfQi6K1fFYu60WLSiHvWQjPis6pBD/UPAT4JzzjRJ873eXyGnoPfpHyTsjAucEHjogXjBK8IDr0Ca3hVRdzw3/oYrJY9OV+r2ZDj7uY9BOdozyAKsJzmQ3lUEV4NL6Bj+Adk/OJPcgzP4F76Qc422JuZ0/gsrRCYUN5Go6xuK3oyce52zspymOz6B4XTylS6Xtgjasjw0S/C67DW3BB5qrChp6Bq0X3Uw45e7KPqykEeXO0cPD7oPAN5R75Hp6KF4rEFNEP72R+c/EMyFQUhOawmf3mZyFPtoqnUI1/wR+FMaWS4BkOEgAAAABJRU5ErkJggg==>

[image18]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACoAAAAZCAYAAABHLbxYAAACvElEQVR4Xu2WWaiNURTH/2ZCZEiKSxkyhyJKuZQoyYvEg7x6oQwvijwJUWT2JFKiXEKm0pUh8YCUITKErqFrKmMJ//9Ze5+zv/19n4frqk+df/3qW2uv75x11l577QNUVdX/qc6kgQyN/C3JKnKP3CDnyJhEhGk0qSeXYXHLSYtERDNpI/lFRkT+DWQTaeXsSeQlGVCOAGrIO7LA2d3IXdgPbFYNIl+RTrQT+Qiraqg9ZF1g7yT3A1taRD6TLpH/r3SM7Ec6Uf0A+UYGPklV3uaetb2vyZHKckm1sHfnRv4mazrZRVYgnWhH8h221YqTOpCHZLKz+8De2+tsL/Wx/GHlm6zW5ArpgexEpfXOL7TF52GxXuPcmtoh1HDn107NJA9gfVxH1pAz5Cm5RCbYK/laQpa657xE1Z+qlk9W1R0frKuy8u8OfJKmh/xHYRNlImx3dBZmu5h2sIQ/waZGpnQyr5I2zs5LdBZ5BDscz2AxX2BfLNU6358S9XoDOw+hBpKf5FTkL2s7bEu8shIdAvu1/jB1JYdhcbecL2/rhzn/gcCnOR0nKmliqNrxdCn1z8nIl5XoVlhPxdoBi+1JervnfYmIymFSj3u9QHaiF2Gx+qyElpG35FWAKqfgRnLbxal6m91zKFVasb2crfdPVJZLmgaLmRf48hLVrad2ahsvZEmtEFd0NbmG9FU4BckBr2mgkRVKxdCXq128lOjxwJZ0w6lHD0X+XOkwKNFRga877ABtIe2dT/16h8zwQbBZ+oEsdLZa4jlZWY4wKdFvsGtY0pyuh/VuPx+Up/nkCfkBS/Q9bBp49SUHYR/2GDZ3pwbrXmPJBXKd3CSLE6smJXqWrIX1vrZclewfxBRCeT1aOOmyKHyimpFqq9PxQpE0BzYOdQaE+n1wIqIg0p8f/8dbo07XduoWqupf6zfPv6ynNYrf1AAAAABJRU5ErkJggg==>

[image19]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACoAAAAZCAYAAABHLbxYAAAC50lEQVR4Xu2XWahOURTH/+bMUtcQIaQMD+4VUcotQyKkkBfJmxcSRcpwKfHCAyXDg2t68GCIMhRdIUmmPCBDkZkMD+b5/7fWOWef830f97qp79b3r1/dtc7ae69v77XX7gIlldRwNJmcJ5fIDbKcNElFmJqTFeQ6uUz2kJapCGAwqSHnyBWyiDRKRfyjRpNrpKPb48hPsj2OMLUgR8kB0oa0hSWyJIjpQV6TWW5rTv3wZXFEPVQNS2yO2/r178k3JMlLVeQlae32BNi4XVEAtZncCmxpLmy+9hl/nbUGtuD0wPeR/ECSVDvygWyLI8y3kQxzWz/wOdkfR5gqYfPPyPjrLC3QKbAHwSY+Gfi0iHzanULqDovZkfGXu39txl8v6XhUh09I38C/AUmi+8hpcpWMD2KGeszWwCcNdL9KZCK5Datj1fpKcpzcJ2fJcBvyZ+kGPyBvkTtgL2yxm6Sz+6aRL0hiR3nMFrcj9Xf/QdgFHEE+w8prisfooirhd7CuUSvpknwl8wOf6k6LrQt8jWE7c8btSvw90UgvyKHAlnSCuhc60VpLi2tQtFs6Ti02M44w3SHfYRer0NEPcL9OLJJKK5uopI6h3dYm5GgIrOBDVcMmX+/2KrcnRQEuTSy/+mdX/3tnKiK5TOFpPEL+RLVBitVcKXWD9UvVWpfAH9XkJrfHuJ1tMXdhZdLK7WfkSPL5t8Yi9zQKJao7oDaoFzAlJadJXiFZTLrg/qlua6AuWfjCyKfiPxz41PBVDqEWwhbvEPiUaDhO6gMrN3WVvNKH3Ugm0g5ogCYK32i92Y9hxywthiXfO46wXirfbLfLyEOyNI4wKdFPZKTbelhqYLXbMwrKSjuzGnaM92DbrySahUGuBbA+qIRPwXpkVhWwPnsR1mvnpb6alOgJ2Kuofqo1tWG9gpiiUKEaLTo9RQNIVD3yDTmW/VBM0rOrDqOOInR5+qUiikRNkfznoI6iC5v3FSrpf+oXM2WyFw72QgoAAAAASUVORK5CYII=>

[image20]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGEAAAAZCAYAAAAhd0APAAAEYUlEQVR4Xu1YbYhVVRRdZmValIqiRphQKdafiiLNoklI7Ef0BWmQaCRpZBQJZRLOJYgygv5EKJgfUVFBRZ9iFiZIP8pMIvpAzNHEDDRKswKLWmv22fPu3TP3zbzeY5yGu2Ax9+x97pn7zjpn730OUKFChQoVBgCGkxOicbBiPHlaNCZcTG4ht5E7yKXkkEKPIpaQR8h/Er8turthJWp9fyc3kuekZ9n217oOPmgizybvJw+RlxXdnZhI/kzOS+3R5Nfko109yqHJ3QebyJ7GFk6CTbr6fJ/ajmEw4Qe1CB2wCf0c5RP1HLqv5MXkMfKsYI/IyCdgYz9TdHVhJvkwynfMKxhAIrSRb5NXB3srsAw9i6Cd8hP5erC3wfrfFuwRGXkTuZv8kRxa8BrWkJNQLsLLGEAiCOfCPvoD8prgawZlIiguy74u2C9Jdq3yeshgIjwO6z+r4LVw8356/t+I4DiPXE9uRmvEKBPh8mRfHewXJfsLwR6RwUTw/hsKXuBW8r70XCbCS+QB8g7yVViB8BV5e65PRu4hj5KPwRaq8ozynMKZig6Hctrz5FvkpvT3w5y/YVwAmwgN0owYZSJoTNlXBfvUZH8z2CMymAjCl7BJGtHlBV4jx6XneiLId2/ONpv8m7wztTXGPbB+Cn36PkFFh3aRxj092daSK9KzcANM1KYxBfaxEuO/5IwyEdqSvRUiPAJ7x1fwSPLd9CyUifAi+Us0Eu/B8pWLeiFsjAe6ehjuSvaHUvsb8tmauxNvhHZT0IcoxipnlNX8PcFFUPjJoywc+Q/WBNVDhpoIk2Dv+MQvhE2Qo1ER/GxxVWpPTu0ogkKR7B5yNJ7ae2FRZE6ytwRaWRnsMLWg4OkdLsIVwa6TquwxlntifjLYIzLy5lz7E/I4OQYWj0flfI2K0A57x3fW+akdRdC5Q/bvUltltcb8I9lF5ZCmoEEV476Ara6Ti+4+wUWYFh3EQfKdYLsO1n9usEdk5C25tpKw3lNVFUNZoyL4Tpie2mUiKF/I7jvBv0eV2ZWwyCG/ioeGcSbs1LqTXESeUnQ3BBfBf1AeOqztCrYHYVcK2n31kMEqIIcm5C9YUo0C1hPh12iEhVydxv2E7SLo2/JQ8pZdiVvYAytoHKfCdkVPC7AUZ5DLYStfJ1cN0iy0k/Sh10YH7KyglTg/tceSP8ASbT0oYapMVMjKX0WorP4NtWpF0CWd/r+uLeKdlEQ4DBPUfTfCxNSOdLgIWjB+4SebDolbUYsQHbBc4N+kXKIEr3ntFUq0ujjbDlv5rZh8xWUlKP0g/YA/YRPRnu9EXEp+TH4KE99r+zKonNRq15iids2M5NMd1Lr0LKik9Is6URd/+apJIiiEaCV/BMsrn5HX5/oILsLTsHOAwozywFMoCi5BtPMVnlRhaVEoLPUJqgLuRnNhZzCjLCdU6EforFSJcILhZbNuZCucACgPKNlLBJ1DVDFW6GcoT3q1owqqFUVLhQoVuuFfSEYfPGX+RVgAAAAASUVORK5CYII=>

[image21]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGcAAAAZCAYAAAAsaTBIAAAEjklEQVR4Xu1YWahVVRj+Khu1NIqoRL2UGGFRhGFS5taISB8q6CEfNAqVCJs1bNJIFKIXB3AoiEvRQ0g2OhSZG3sIkUaiOa0Is2hQaDDR7Pv41zrn34tzjvucq3jvZX/wcc/+/7XXunt9+x/WBipUqFChQj/H8eTZ5IDU0V+hhz0pNbbAQvIK8lTyDPImcmthRBGXkrvJ/eTB8HdoYUQR18PGif/C7j2O/MTZR9ZG90McQ55L3kP+So4puptCmxQ3yPNRP6gJtOk/wMbPSXwez5OfwcZ1Ofux5JPB3ufEOYGcSp6YOhrgO9gGvA972LLiCHvJL8nvydfJa4vupsjIlbBI+LDoqmEQ+RKZw/4vRbXHHcHeZ8Q5mbyL3AaLBEVFWcxD++J8mxpKIiOXkM/C1hxd8BqmkbeiuTizgr3Xi3MKeT/sLbwPJlK76EScb1JDSWQwcRRpWnNxwWt4hTwNfVgciaKcLVHuRWeiRHQizg7YfW+Rn8JSlTb0UMhg4qhu7YKlVh/lZ5Evht85GoszM9gVYS/A0up28gnYvMIU8ivyd3ItuYDcCFvvXVgzE6H1HyPfIDeQm8gPyNPdmFKIouhmpbF2Oqxm6EScv8mbw2+1tu8EHiqdZjBxhGWwdcfXvMDdqM+bo7U4EkY1VhhB/kR2h2t1keNgnd4/5A3Brloskf6EdZDCdNj/HjGM/IM809laQpERI0WilCn4ZdGJOBcn17fB5rgxsafIUBdHm6d7Vte8wNuoZ4EcjcWZEexxcyPmBvvlzvYLLE16KB3+R64P14p61WqffVQTh7jrltCD7CQfxOGJFo8ojn+odnENbI6nU0eCDHVxBKUjpR5FgDbtOefL0Z448WzkW3rtWSqO8AUsqtSax/kULa/CyoQyVFvQDXo7PoKF/+ESKYozNnU0wSLYG+kL8tWwOZS3WyEjl7prNQS6T2nncXKy8+XBV1acCcHuI/FHNBZnC2zsObBUPB921pNN/BgdCCQMRF0ktc09aQaEKI4vkq2Qw8Zf6WzaVNmecbZGyGC1JkLpUfetId+D1a+IPPjKihMj5yFnaybO57C6qYhV1A+GiXQR+RQs7d1ZG90BpOwD6HnHFsVR6kwxgLwFxQ1SWlL984hzXJfYU2Tk8sSmbu8AuSqx52gtzmWJ/WHYPBc4m8R5zV0L58M2P3aF3bA5PdQg6Jl6DIkicXTS7+Sso5DWw05MHcRsmE8n9ojhsBcibsKFsLZYn1xaQW2uWtYcxZTxCGyNCc4mbA32rsSujfyLfBmWRQRt+M+wdtpD4uwlrwrXGr8ZVotGBFs37AWJDYDKxdcon0lKQZMqFJVPywj0JuzzS/wYqYdQgV7gxkyCfWpRI+Kht1br7IB9LdAGxzNGI1wCm1/riPtQn/M8WIGObbiagj1hnKhWWPUgzi9xlBolpp5Bm63PUDqMp628xNEY1Umdd5TOFDFdbswKWNRtJNfBXp7bnb/CEUKzmlOhF0AH00qcXgidYXR20SeZCr0I+gT0G+p1Sw3AqMKICkcNOgLEBkJNgs5PiqQKFSocdfwPptIdHaJh3UkAAAAASUVORK5CYII=>

[image22]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACYAAAAZCAYAAABdEVzWAAACuUlEQVR4Xu2WW6hNURSGB3IrjluukeNaHoQojw4pIQolt7yRkuJBFEVupfDgQW4phULIiZNbbHIp95AUyiW5RMfLKSHH/xtjrj3W3Htt++W8rb++2uNfs7XmnGPMMbdIrlwVNQdcBEfBgOhZUFtwGLSLH5TTOHAZPAT3wNT0Y2kDNoJH4BZoAMP9AKgOfAZd7fd3sAL0KA6RMaAAtjkvU1PAVzDZ4oWgUdIr2gkeg04WLwMfQc9khEg92Oti7txycFJ0IRfAGfASdHDjyqo7+AbWOO8uaAaDLe4PfoL5yQiRVqIT2+q8N2Czi3eB8S6mzoFJkVdWfDEn0c95s8EW0Y9TXDXHjExGqArguYs/gE0ujic2DxxycUXxxZ9iM9JB0YkNjPyz4A/oaPElsKf4+F/6Qn11A09EM/Rf1Yh+kLWzFJwHz8ABKdYSRZ/j+jqPYu34lE8D70QnUQeOm09xcQtcXFHDRF/M07PBPBblfdFCDromOq6P8yh+mP4o5zFd18Ep0Mu8CaK7V7VYM3zxL9DZ+SvND0VasLiaicVqDx6AWot5kI6BK2C6eSViavjiF5HPdkF/h8VZqTxh/tDI9+JhWGW/2QufgrmimbkNetuzlNiBf4uuyIvp4AfDCdpn8aBkhIrFTz8Uf6wRos2YE6JmgB+gtcWzwGr7XaKbkj7y1CLRD4YexWbKeGwyQsWPxrsdxFZzFYx23nrwxcWscR6KsmJjbRKthaB1kp4Iexx3likO4m7ztsi6WpaA7ZHHtPqJ8UrLnFgX8F6KHZt19BrsTkaoeCXxnuQ9SK0V7fxsDbF4Gnl7xClmbTGVIbVs5JmppIaIFjh70FvRHQtdP4gv44pZvLzkebXENRd0BEyMTdGCfwUW2+87UnrSW0y8gvbHplMtOA1ugJnpRy0r/iPx9ZorV65q9RegYI79QzbRMQAAAABJRU5ErkJggg==>

[image23]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGgAAAAZCAYAAADdYmvFAAAE80lEQVR4Xu2YeaxdUxSHf2ZqLFXEkNKKIU3LP40xXgxBEKSCUNKIajRpoiEihDw0EVNETBEJjxhCJYYYaq6phJhaQoyltMYKMc/rs/Z+d539bnvPfZ5/Xs+X/HLvXmffc87ea+21175SQ0NDQ0NDbdYxbVEah4LDTAtMP6TPaaZVKj3qMdZ0hmkn09qmbUwzTbfETsOQzU0/mv42fVpc+8/sb3rVtJlpA9M18gfNjp1qsp/8t1E/mQ6InYYpa5me1v/goBdM+4T2aqYPTH+Ztg72OvSYvjYtMr1rusm0fbg+3LlNQ+wgnPGn6UPThsF+gzz6pwdbHfY29ZXGlYhbNcQOWtX0rdwZ44L98mSbFWx12EvDw0GD2X9hyB0Eu2rgHvGo3EGlvRN7mu43XW963PSW6fRKj/YcaXrQ9IDpGdMjpiPCdSqj202vmJ6TB8Gm4ToQHE/Kn0navlfVimo70xz5PdCd8iImQ3paavpNPo4rTfeZPjFdrYFO21H+zu/I73ux6R5VHcRvzpWP62HTE/L9fmTo0zW89O/ygbLCumF30+fyKg6YoC9NvblDG6j82LfWT2022+dNR6X2xvIUfFFqk5YZLI7MHCSf2CmpTVVKgDHJwD74len41AYCZ4lpq9Rmv71U/jsmcYdk597YDk1tINssM12h1hxNMn2vqoNOlAdNhmeQsUYFW9cQqTxoQnmhBuvKIzVys+kXeSnajmPk5f2YYDvFdHD6ziT8Ib935hD5pI2XO2yx3KmZMaa5at2D1fx6/1WHieV3dwfbZPl9e4ON6hbbecHGyvrOtGawASslOug608vy81HmRtNGod0VJ8jr+Z5gIwoY4IpEOlkeF8oHeFx5IUGqwAG/mubJ+8fU8758dbwYRIpiIvY17SG/P/tmO0bLrxN4JUQ39x6R2qRV+rICM5sk2wWpjVN415f6e7QoHXSy/LesGpx6mlrP6pqJ8lTDoAfLs/LJI6ozRB4vyQF2ebAHUZbTD32j1gomUj9L39tB2iqjPsIey3VWcgmrjGvbpnZOjaS1DPsFNgIHSNu0Y+rKlA5iD2L8zGse2xsahJPI82+r+mI98vRTF5zCSiA9xiV9ifzFYv6PkOt3Tt/J0afKnXJXsjEgUmR0eiQfjq8tLyQoJrgeU1mGtMh+u15qs890chBj+9k0v79Hi9JBvBvHFxxFOmaP43w5I/TpCAN/SJ5/I+ebDi9snWBzZbOMEKXsMaSKdkyVl6cRoo7fQa98gsqVfY682uIvpS9M76laaVFsXJa+U1BQ9ERWlxcwTGomp7h2DpodbKR0VnkZNMxjXO198jQXYeWdVdhWCBHOvvNmEgMh75Nnc2TXBYcy4LwJ4nQOwuVLRqbKn0+KzVDynpm+UxywihaqVXERjVRy2SFHyyOTKM9VFXtGfu4u8n0gvsfZ8tQzNtiOlTsjBmZegdnZME6eKaYFG3shc0Ywbil/jz75nOb5IJgIpN1SuyMs15wbSzFgbtgtDJI/XBebXtPAlVlCYcL/f5xLOFdwVmDDXyP04T9CSuaP5c6iL9VV5ED5+YeSnNQ1q3r532DjvMK7cXa5Q9WKkxTI/4aMnU+eQaTn/YP0/VF/b3f6Y/J7XiVf9U+pNX9T5GmXQCAbMLZ5ppPUMCgIxrz6+KRNxZbTGKu1U8Cyl5UH2oaGhoaGhoaGhpWKfwDi0S+CWSI2OQAAAABJRU5ErkJggg==>

[image24]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADkAAAAZCAYAAACLtIazAAACXklEQVR4Xu2WO2tUURSFl09EBREsTBBEES0MPgrBBJJCoo2NjWhhqaKNgr/AQlBsVHykS/AnaBSN2Nj4fitIIIkIPoIiYiMqvtZi7zuzPVxu7gwqGbwfLGb2Omdmzrr3nH0HqKioaAUWp0YOm6ifrqvJ2KRlNtVFnacuJGN5TKPaqTdokZB7qbfUReobyoXMeIoWCRn5jMZCPsZ/EPIB/k1IHac/RqMh78JCbqDOUQ/dWxMnkSmwY6Gx69Q9alcYj43spntzgydNd3+QekF9orZRN6jnVKePT0gzIV9Tp2DNSGHuULfiJHIcNnee12paw9Qhr/XZpdQ71EOK+bD1xJBLqH73rsAapt7rN0rRTEhd0bid+qjvoe6GLWJL8MRu6ge1KnhP8HtIocXHkGKneztgF3Y7tTCMF6KQ6rJlUUhtvchJ2AKmen3G6+W1GUaP+9ndFDrjjYRcG7zSKOSl1CxAIdNFnYAtQFtQ6Kyq1jaLrHf/bPC01dPvKwq5InilUcjLqVlA3pVPQ572uqM2w9jo/pHg6SzfDrXIdkZeyGXBK41CDqVmAXlnKAuZLUqdV/XW2gxjn/vrgqdOmW5//QvTvJnBazqkFvWFupYOFPAMdjcj2Z2bE7wB2LwFXi+iRqljtRmG5o2FeiX1EfZ9eixlF+6Ae6u9npDNsB/8APugNE6NwFp4HuqYr1Cf/5LqhS1Qfw3lvYfdLaEmtJ+6Tz3y1z0+FmmDHRedYwU+TB1F/XcOwp7F6sqqv8LW8VfQFZ3h79XC9V7eLK+FzmTcYs2ix1N2visqKioqJgW/ALqOohLaQ4YeAAAAAElFTkSuQmCC>